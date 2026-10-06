import Foundation
import AVFoundation
@MainActor func render(_ settings: NativeFXSettings, rate: Double, frequency: Double? = 1000, duration: Double = 1, item: Bool = false, analysis: Bool = true) throws -> [[Float]] {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let player = AVAudioPlayerNode(), chain = NativeEffectsChain(reorderable: !item)
    engine.attach(player)
    chain.attach(to: engine, input: player, format: format)
    engine.connect(chain.output, to: engine.mainMixerNode, format: format)
    chain.apply(settings)
    if analysis { chain.observe(["Delay","Reverb"]) }
    let count = Int(rate * duration)
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
    input.frameLength = AVAudioFrameCount(count)
    for i in 0..<count {
        let sample: Float
        if let frequency { sample = Float(0.5 * sin(2 * .pi * frequency * Double(i) / rate)) }
        else { sample = i == Int(rate * 0.1) ? 1 : 0 }
        input.floatChannelData![0][i] = sample
        input.floatChannelData![1][i] = sample * 0.5
    }
    player.scheduleBuffer(input)
    try engine.start(); player.play()
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    var result = [[Float](), [Float]()]
    for _ in 0..<Int(ceil(Double(count)/512)) {
        guard try engine.renderOffline(512, to: buffer) == .success else { fatalError("render failed") }
        for ch in 0..<2 { result[ch].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![ch], count: Int(buffer.frameLength))) }
    }
    result = result.map { Array($0.prefix(count)) }
    if analysis {
    precondition(chain.spectrum("Reverb")?.count == 4096*MemoryLayout<Float>.size, "reverb spectrum receives stereo PCM")
    // AVAudioNode delivers tap buffers asynchronously even in offline mode.
    // Wait for the first frame, keeping a bound so a missing tap still fails.
    var delayFrame = chain.spectrum("Delay")
    let tapDeadline = Date().addingTimeInterval(0.25)
    while delayFrame == nil && Date() < tapDeadline {
        Thread.sleep(forTimeInterval: 0.001)
        delayFrame = chain.spectrum("Delay")
    }
    precondition(delayFrame?.count == 4096*MemoryLayout<Float>.size, "delay spectrum receives its own output")
    chain.observe([])
    precondition(chain.spectrum("Reverb") == nil, "closing editor stops analysis")
    }
    let meters = chain.compressorPeaks()
    if analysis && settings.compressorEnabled { precondition(meters[0] > meters[2] && meters[1] > meters[3], "compressor meters read its own input and output") }
    precondition(result.joined().allSatisfy { $0.isFinite && abs($0)<2 }, "finite bounded output")
    engine.stop()
    return result
}
func rms(_ values: ArraySlice<Float>) -> Double { sqrt(values.reduce(0) { $0 + Double($1)*Double($1) } / Double(max(1,values.count))) }
func stereoFrame(rate: Double, frequency: Double, gain: Float) -> Data {
    var samples = [Float](repeating: 0, count: 4096)
    for channel in 0..<2 { for i in 0..<2048 { samples[channel * 2048 + i] = gain * Float(sin(2 * .pi * frequency * Double(i) / rate)) } }
    return samples.withUnsafeBytes { Data($0) }
}
func frameRMS(_ data: Data) -> Double {
    data.withUnsafeBytes { bytes in
        let values = bytes.bindMemory(to: Float.self)
        return sqrt(values.reduce(0) { $0 + Double($1) * Double($1) } / Double(values.count))
    }
}
@MainActor func testIdleRouteGate() throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    var sourcePulls = 0
    let source = AVAudioSourceNode { _, _, _, buffers in
        sourcePulls += 1
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size { samples[index] = 0.125 }
        }
        return noErr
    }
    let route = JarasChannelRouter.makeNode()
    engine.attach(source); engine.attach(route)
    engine.connect(source, to: route, format: format)
    engine.connect(route, to: engine.mainMixerNode, format: format)
    JarasChannelRouter.configure(route, first: 1, count: 2)
    try engine.start()
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    func render() throws -> Float {
        let status = try engine.renderOffline(512, to: buffer)
        precondition(status == .success)
        return (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
    }
    let audible = try render()
    precondition(audible > 0.1 && sourcePulls > 0, "an enabled route must deliver audio")
    JarasChannelRouter.setRenderEnabled(route, enabled: false)
    let before = sourcePulls
    let releasePeak = try render()
    precondition(releasePeak <= audible && buffer.floatChannelData![0][511] == 0, "stop performs its existing short de-click ramp before sleeping")
    for _ in 0..<8 {
        let silence = try render()
        precondition(silence == 0, "sleeping output remains digitally silent")
    }
    precondition(sourcePulls == before, "sleeping route must not pull the upstream track and effects")
    JarasChannelRouter.setRenderEnabled(route, enabled: true)
    let restored = try render()
    precondition(restored > 0.1 && sourcePulls > before, "waking route immediately restores audio")
    JarasChannelRouter.configure(route, first: -1, count: 2)
    for _ in 0..<4 { _ = try render() }
    let unpatchedPulls = sourcePulls
    for _ in 0..<8 { let silence = try render(); precondition(silence == 0, "an unpatched hardware route must remain silent") }
    precondition(sourcePulls == unpatchedPulls,
                 "a hardware route without destinations stops pulling its upstream processors after the ramp")
    JarasChannelRouter.configure(route, first: 1, count: 2)
    let repatched = try render()
    precondition(repatched > 0.1 && sourcePulls > unpatchedPulls,
                 "assigning a hardware patch resumes audio without rebuilding the graph")
    engine.stop()
    print("UNPATCHED_HARDWARE_ROUTE_RELEASE_SLEEP_AND_LIVE_REPATCH_PCM_OK")
    print("IDLE_ROUTE_STOPS_UPSTREAM_RENDER_WITH_DEVICE_CLOCK_ALIVE_OK")
}
func testRoundedSpectrum() {
    let flat = [Float](repeating: -24, count: EQSpectrum.binCount)
    precondition(EQSpectrum.smoothedBins(flat) == flat, "visual rounding preserves a flat measured spectrum")
    var peak = [Float](repeating: -80, count: EQSpectrum.binCount)
    let center = peak.count / 2; peak[center] = -12
    let rounded = EQSpectrum.smoothedBins(peak)
    precondition(rounded[center] > rounded[center-1] && rounded[center-1] > rounded[center-2] && rounded[center-2] > rounded[center-3], "a narrow FFT spike becomes a rounded hill instead of a square step")
    for offset in 1...6 { precondition(abs(rounded[center-offset]-rounded[center+offset]) < 0.001, "rounding cannot shift a frequency peak") }
    precondition(rounded.allSatisfy { $0 >= -80 && $0 <= -12 }, "curve smoothing cannot invent out-of-range levels")
    precondition(EQSpectrum.smoothedBins([.nan, .infinity, -200, 300]).allSatisfy { $0.isFinite && $0 >= EQSpectrum.minimumDB && $0 <= EQSpectrum.maximumDB })
    precondition(EQSpectrum.smoothedBins([]).isEmpty)
    print("EQ_RTA_ROUNDED_HILLS_BOUNDED_FREQUENCY_ALIGNMENT_OK")
}
func testSpectrumWorker(rate: Double) {
    testRoundedSpectrum()
    let tone = rate * 46 / 2048
    let input = stereoFrame(rate: rate, frequency: tone, gain: 0.5)
    let output = stereoFrame(rate: rate, frequency: tone, gain: 0.125)
    let analyzer = EQSpectrumAnalyzer()
    let spectrum = analyzer.analyze([EQAnalysisFrame(input: input, output: output, sampleRate: rate)])
    let peak = spectrum.input.indices.max { spectrum.input[$0] < spectrum.input[$1] }!
    precondition(abs(log(EQSpectrum.frequency(at: peak) / tone)) < 0.08, "FFT finds the actual PCM frequency at both sample rates")
    precondition(abs(spectrum.output[peak] - spectrum.input[peak] + 12.0412) < 0.01, "FFT preserves the measured input/output level difference")
    let twoHeads = EQSpectrumAnalyzer().analyze([EQAnalysisFrame(input: input, output: output, sampleRate: rate), EQAnalysisFrame(input: input, output: output, sampleRate: rate)])
    precondition(abs(twoHeads.input[peak] - spectrum.input[peak] - 3.0103) < 0.01, "both simultaneous playback heads contribute to the spectrum")
    let decayed = analyzer.analyze([], elapsed: 0.1)
    precondition(abs(decayed.input[peak] - spectrum.input[peak] + 7.2) < 0.001, "inactive PCM decays smoothly instead of freezing")
    let malformed = EQSpectrumAnalyzer().analyze([EQAnalysisFrame(input: Data([1,2]), output: input, sampleRate: .nan)])
    precondition(malformed.input.allSatisfy { $0 == EQSpectrum.minimumDB } && malformed.output.allSatisfy { $0 == EQSpectrum.minimumDB }, "invalid frames cannot corrupt the display")
}
@MainActor func testEQCapture(rate: Double, channels: AVAudioChannelCount = 2) throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let player = AVAudioPlayerNode(), chain = NativeEffectsChain()
    engine.attach(player); chain.attach(to: engine, input: player, format: format)
    engine.connect(chain.output, to: engine.mainMixerNode, format: format)
    var settings = NativeFXSettings(); settings.eqEnabled = true
    settings.bands = [EQBand(frequency: 1000)]
    settings.bands[0].gain = -12; settings.bands[0].q = 1
    chain.apply(settings)
    precondition(chain.eqSpectrumFrame() == nil, "closed EQ has no analysis source")
    chain.observe(["EQ"])
    let count = Int(rate)
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
    pcm.frameLength = AVAudioFrameCount(count)
    for channel in 0..<Int(channels) { for i in 0..<count { pcm.floatChannelData![channel][i] = Float(0.5 * sin(2 * .pi * 1000 * Double(i) / rate)) } }
    player.scheduleBuffer(pcm); try engine.start(); player.play()
    let rendered = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    func renderBlocks(_ count: Int) throws { for _ in 0..<count { let status = try engine.renderOffline(512, to: rendered); precondition(status == .success) } }
    try renderBlocks(16)
    let frame = chain.eqSpectrumFrame()!
    precondition(frame.input?.count == 4096 * MemoryLayout<Float>.size && frame.output?.count == frame.input?.count, "EQ captures real stereo input and output PCM")
    precondition(frame.sampleRate == rate, "capture carries the actual device sample rate")
    let attenuation = 20 * log10(frameRMS(frame.output!) / frameRMS(frame.input!))
    precondition(abs(attenuation + 12) < 0.1, "output spectrum comes after the actual EQ: \(attenuation)")
    precondition(chain.eqSpectrumFrame() == nil, "an unchanged PCM frame is consumed only once")
    chain.observe([])
    try renderBlocks(8)
    precondition(chain.eqSpectrumFrame() == nil, "closing EQ disables input and output capture while playback continues")
    chain.observe(["EQ"])
    precondition(chain.eqSpectrumFrame() == nil, "reopening cannot replay an old capture")
    try renderBlocks(3)
    precondition(chain.eqSpectrumFrame() == nil, "reopening waits for one complete fresh analysis window")
    try renderBlocks(1)
    precondition(chain.eqSpectrumFrame() != nil, "capture resumes without rebuilding or reconnecting the audio graph")
    settings.eqEnabled = false; chain.apply(settings)
    try renderBlocks(16)
    let bypass = chain.eqSpectrumFrame()!
    precondition(abs(frameRMS(bypass.input!) - frameRMS(bypass.output!)) < 0.00001, "bypassed EQ still reports its actual matching input/output")
    chain.observe([]); engine.stop()
    testSpectrumWorker(rate: rate)
    print("EQ_RTA_REAL_PCM_FFT_BOTH_HEADS_BYPASS_AND_CLOSED_CAPTURE_OK rate=\(rate) channels=\(channels)")
}
@MainActor func testItemFades() throws {
    for rate in [44_100.0, 48_000.0] {
        for offset in [0.0, 0.5, 1.0] {
            let engine = AVAudioEngine(), player = AVAudioPlayerNode(), chain = NativeEffectsChain(reorderable: false)
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            engine.attach(player); chain.attach(to: engine, input: player, format: format)
            engine.connect(chain.output, to: engine.mainMixerNode, format: format)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
            var clip = AudioClip(id: UUID(), name: "Fade", startTime: 10, duration: 2)
            clip.fadeIn = 1; clip.fadeOut = 1
            // A tempo fragment retains the original item envelope.
            if offset == 1 { clip.startTime = 11; clip.duration = 1; clip.fadeTimelineStart = 10; clip.fadeTimelineDuration = 2 }
            chain.configureItemFade(clip, position: 10 + offset)
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            input.frameLength = 512
            for channel in 0..<2 { for frame in 0..<512 { input.floatChannelData![channel][frame] = 0.6 } }
            player.scheduleBuffer(input, at: nil, options: .loops)
            try engine.start(); player.play()
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            var maximumError = 0.0
            for block in 0..<Int(ceil((2 - offset) * rate / 512)) {
                let status = try engine.renderOffline(512, to: output)
                precondition(status == .success)
                for frame in 0..<Int(output.frameLength) {
                    let time = offset + Double(block * 512 + frame) / rate
                    func curve(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }
                    let expected = 0.6 * curve(time) * curve(2 - time)
                    for channel in 0..<2 { maximumError = max(maximumError, abs(Double(output.floatChannelData![channel][frame]) - expected)) }
                }
            }
            precondition(maximumError < 0.0001, "sample-clock fades differ from their drawn curve: \(maximumError)")
            engine.stop()
        }
        print("ITEM_FADE_PCM_STEREO_SEEK_REPEAT_AND_TEMPO_FRAGMENT_OK rate=\(rate)")
    }
}
@MainActor func testLimiter() throws {
    var settings = NativeFXSettings()
    precondition(settings.limiterEnabled != true && settings.limiterParameters.ceiling == -0.1)
    settings.appendNative("Limiter")
    settings.limiterParameters.ceiling = -6
    settings.limiterParameters.inputGain = 12
    try settings.validateForClip()
    let duplicate = settings.appendNative("Limiter")
    settings.instances?[0].settings.limiterParameters.ceiling = -9
    let encoded = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(NativeFXSettings.self, from: encoded)
    precondition(decoded == settings && decoded.isEnabled(duplicate))
    settings.setEnabled(duplicate, enabled: false)
    precondition(settings.isEnabled("Limiter") && !settings.isEnabled(duplicate))
    var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(NativeFXSettings())) as! [String: Any]
    oldJSON.removeValue(forKey: "limiter"); oldJSON.removeValue(forKey: "limiterEnabled")
    let old = try JSONDecoder().decode(NativeFXSettings.self, from: JSONSerialization.data(withJSONObject: oldJSON))
    precondition(!old.isEnabled("Limiter"))
    for rate in [44100.0, 48000, 96000] {
        for channels in [1, 2] {
            let engine = AVAudioEngine()
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
            let player = AVAudioPlayerNode(), limiter = JarasDynamics.makeLimiter()
            engine.attach(player); engine.attach(limiter)
            engine.connect(player, to: limiter, format: format)
            engine.connect(limiter, to: engine.outputNode, format: format)
            JarasDynamics.configureLimiter(limiter, enabled: true, gain: 12, ceiling: -6, release: 0.05)
            JarasDynamics.setCompressorMeteringEnabled(limiter, enabled: true)
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
            input.frameLength = 8192
            for i in 0..<8192 {
                // Alternating impulses straddle render-block boundaries.
                let value: Float = i % 511 == 0 ? (i % 2 == 0 ? 3 : -3) : 0.7 * sin(Float(i)*0.3)
                input.floatChannelData![0][i] = value
                if channels == 2 { input.floatChannelData![1][i] = -0.25 * value }
            }
            player.scheduleBuffer(input); try engine.start(); player.play()
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            let ceiling = Float(pow(10.0, -6.0/20))
            var highest: Float = 0
            for _ in 0..<16 {
                let status = try engine.renderOffline(512, to: output); precondition(status == .success)
                for i in 0..<Int(output.frameLength) {
                    let left = output.floatChannelData![0][i]
                    precondition(left.isFinite && abs(left) <= ceiling + 0.000001, "ceiling must hold for the very first sample and block boundaries")
                    highest = max(highest, abs(left))
                    if channels == 2 { precondition(abs(output.floatChannelData![1][i] + left*0.25) < 0.000001, "stereo linking preserves image and phase") }
                }
            }
            precondition(highest > ceiling * 0.999)
            let meters = JarasDynamics.takeCompressorPeaks(limiter).map(\.floatValue)
            precondition(meters[0] > 2 && meters[2] <= ceiling + 0.000001 && meters[2] > 0.49)
            JarasDynamics.configureLimiter(limiter, enabled: false, gain: 12, ceiling: -6, release: 0.01)
            let bypassInput = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
            bypassInput.frameLength = AVAudioFrameCount(rate)
            for ch in 0..<channels { for i in 0..<Int(rate) { bypassInput.floatChannelData![ch][i] = 0.75 } }
            player.scheduleBuffer(bypassInput)
            for _ in 0..<Int(rate/512)-1 { let status = try engine.renderOffline(512, to: output); precondition(status == .success) }
            let expected: Float = 0.75
            precondition(abs(output.floatChannelData![0][400] - expected) < 0.00001, "bypass restores unprocessed audio: \(output.floatChannelData![0][400]) expected \(expected)")
            engine.stop()
        }
        var chainSettings = NativeFXSettings(); chainSettings.appendNative("Limiter")
        chainSettings.limiterParameters.inputGain = 12; chainSettings.limiterParameters.ceiling = -6
        let limited = try render(chainSettings, rate: rate)
        precondition(limited[0].map(abs).max()! <= Float(pow(10.0,-6.0/20)) + 0.000001)
        chainSettings.appendNative("Limiter"); chainSettings.instances?[0].settings.limiterParameters.ceiling = -12
        let twice = try render(chainSettings, rate: rate)
        precondition(twice[0].map(abs).max()! <= Float(pow(10.0,-12.0/20)) + 0.000001, "duplicate limiter is processed in chain")
    }
    print("JARAS_LIMITER_CEILING_TRANSIENTS_MONO_STEREO_BYPASS_INSTANCES_AND_PROJECT_ROUNDTRIP_OK")
}

@MainActor func testSparseTrackChainLiveInsertion() throws {
    for rate in [44100.0, 48000] {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), mixer = AVAudioMixerNode()
        let chain = NativeEffectsChain()
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        engine.attach(player); engine.attach(mixer)
        engine.connect(player, to: mixer, format: format)
        chain.attach(to: engine, input: mixer, format: format)
        engine.connect(chain.output, to: engine.mainMixerNode, format: format)
        for node in [chain.compressor, chain.delay, chain.reverb] {
            precondition(engine.outputConnectionPoints(for: node, outputBus: 0).isEmpty,
                         "unused processors must not participate in rendering")
        }
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 4))!
        source.frameLength = source.frameCapacity
        for channel in 0..<2 { for frame in 0..<Int(source.frameLength) { source.floatChannelData![channel][frame] = 0.1 } }
        player.scheduleBuffer(source)
        try engine.start(); player.play()
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        func check(_ expected: Float) throws {
            for block in 0..<24 {
                let status = try engine.renderOffline(512, to: output)
                precondition(status == .success)
                if block >= 16 {
                    for channel in 0..<2 { for frame in 0..<Int(output.frameLength) {
                        precondition(abs(output.floatChannelData![channel][frame] - expected) < 0.0001,
                                     "live insertion and bypass preserve the scheduled PCM")
                    } }
                }
            }
        }
        try check(0.1)
        let nodeCount = engine.attachedNodes.count
        var settings = NativeFXSettings(); settings.appendNative("Compressor")
        settings.threshold = 0; settings.ratio = 1; settings.makeup = -6
        chain.apply(settings)
        try check(0.1 * Float(pow(10, -6.0 / 20)))
        precondition(engine.attachedNodes.count == nodeCount)
        let destination = engine.outputConnectionPoints(for: chain.compressor, outputBus: 0).first?.node
        settings.compressorEnabled = false; chain.apply(settings)
        try check(0.1)
        precondition(engine.outputConnectionPoints(for: chain.compressor, outputBus: 0).first?.node === destination,
                     "bypass keeps the activated processor connected")
        chain.apply(NativeFXSettings()); try check(0.1)
        engine.stop()
        print("UNUSED_TRACK_FX_OUTSIDE_RENDER_PATH_AND_LIVE_INSERTION_CONTINUITY_OK rate=\(rate)")
    }
}
@MainActor func run() throws {
    try testSparseTrackChainLiveInsertion()
    try testLimiter()
    setbuf(stdout, nil)
    try testItemFades()
    try testIdleRouteGate()
    for rate in [44100.0,48000.0] {
        try testEQCapture(rate: rate)
        try testEQCapture(rate: rate, channels: 1)
        var settings = NativeFXSettings()
        let dry = try render(settings, rate: rate)
        precondition(abs(rms(dry[0].suffix(2048)) - 0.3535)<0.01, "bypass RMS: \(rms(dry[0].suffix(2048)))")
        settings.compressorEnabled = true; settings.threshold = -24; settings.ratio = 4; settings.attack = 0.0001; settings.release = 0.1
        let compressed = try render(settings, rate: rate)
        let gain = rms(compressed[0].suffix(2048))/rms(dry[0].suffix(2048))
        precondition(gain > 0.20 && gain < 0.24, "4:1 compression slope: \(gain)")
        precondition(abs(rms(compressed[1].suffix(2048))/rms(compressed[0].suffix(2048)) - 0.5)<0.001, "stereo image stays linked")
        settings.compressorEnabled = false; settings.eqEnabled = true; settings.bands = [EQBand(frequency: 1000,type:"lowCut")]
        settings.bands[0].slope = 24
        let low = try render(settings, rate: rate, frequency: 100)
        precondition(rms(low[0].suffix(2048))<0.0001, "low cut attenuates out-of-band audio")
        let high = try render(settings, rate: rate, frequency: 4000)
        precondition(rms(high[0].suffix(2048))>0.34, "low cut preserves passband")
        settings.eqEnabled = false; settings.reverbEnabled = true; settings.reverbMix = 100
        var signatures = [Double]()
        for space in 0...2 {
            settings.reverbRoom = space; settings.reverbDecay = 2
            let wet = try render(settings, rate: rate, frequency: nil, duration: 2)
            let tail = rms(wet[0][Int(rate/2)..<Int(rate)])
            precondition(tail>0.00001, "each reverb has an audible tail")
            signatures.append(tail)
            settings.reverbDecay = 0.2
            let short = try render(settings, rate: rate, frequency: nil, duration: 2)
            precondition(rms(short[0][Int(rate/2)..<Int(rate)]) < tail * 0.2, "decay controls tail duration")
        }
        precondition(Set(signatures).count == 3, "Room, Hall and Plate are distinct")
        settings.reverbRoom = 1; settings.reverbDecay = 1
        settings.reverbLowCut = 20; settings.reverbHighCut = 20000
        let openHigh = try render(settings, rate: rate, frequency: 12000)
        settings.reverbHighCut = 2000
        let cutHigh = try render(settings, rate: rate, frequency: 12000)
        precondition(rms(cutHigh[0].suffix(2048)) < rms(openHigh[0].suffix(2048))*0.4, "reverb high cut filters the wet signal")
        settings.reverbHighCut = 20000
        let openLow = try render(settings, rate: rate, frequency: 80)
        settings.reverbLowCut = 2000
        let cutLow = try render(settings, rate: rate, frequency: 80)
        precondition(rms(cutLow[0].suffix(2048)) < rms(openLow[0].suffix(2048))*0.1, "reverb low cut filters the wet signal")
        print("NATIVE_FX_PCM_OK rate=\(rate) ratio=\(gain) spaces=\(signatures)")
    }
}
@MainActor func testCombinedItemEQCompressor() throws {
    for rate in [44100.0, 48000.0] {
        var settings = NativeFXSettings()
        settings.eqEnabled = true; settings.bands[0].frequency = 200
        settings.compressorEnabled = true; settings.threshold = -24; settings.ratio = 4; settings.makeup = 3
        let reference = try render(settings, rate: rate, analysis: false)
        let combined = try render(settings, rate: rate, item: true, analysis: false)
        for channel in 0..<2 {
            let error = zip(reference[channel], combined[channel]).map { abs($0 - $1) }.max()!
            precondition(error < 0.00001, "combined item processor preserves EQ/compressor PCM: \(error)")
        }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), chain = NativeEffectsChain(reorderable: false)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        engine.attach(player); chain.attach(to: engine, input: player, format: format)
        engine.connect(chain.output, to: engine.mainMixerNode, format: format)
        precondition(chain.equalizer === chain.compressor)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 2))!
        input.frameLength = input.frameCapacity
        for c in 0..<2 { for i in 0..<Int(input.frameLength) { input.floatChannelData![c][i] = 0.1 } }
        player.scheduleBuffer(input); try engine.start(); player.play()
        let count = engine.attachedNodes.count
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        func check(_ expected: Float) throws {
            for block in 0..<24 {
                let status = try engine.renderOffline(512, to: output); precondition(status == .success)
                if block > 16 { for c in 0..<2 { for i in 0..<Int(output.frameLength) { precondition(abs(output.floatChannelData![c][i] - expected) < 0.0001) } } }
            }
            precondition(engine.attachedNodes.count == count)
        }
        try check(0.1)
        var active = NativeFXSettings(); active.compressorEnabled = true; active.threshold = 0; active.ratio = 1; active.makeup = -6
        chain.apply(active); try check(0.1 * Float(pow(10, -6.0 / 20)))
        chain.setSourcePolarity(true); try check(-0.1 * Float(pow(10, -6.0 / 20)))
        chain.setSourcePolarity(false); chain.apply(NativeFXSettings()); try check(0.1)
        engine.stop()
    }
    print("COMBINED_ITEM_EQ_COMPRESSOR_PCM_AND_LIVE_CONTINUITY_OK")
}
try MainActor.assumeIsolated { try testCombinedItemEQCompressor(); try run() }


let spectrumStart = EQSpectrum(input: Array(repeating: -72, count: EQSpectrum.binCount), output: Array(repeating: -48, count: EQSpectrum.binCount))
let spectrumEnd = EQSpectrum(input: Array(repeating: -24, count: EQSpectrum.binCount), output: Array(repeating: -12, count: EQSpectrum.binCount))
let vectorStart = EQSpectrumVector(spectrumStart), vectorEnd = EQSpectrumVector(spectrumEnd)
var halfTransition = vectorEnd - vectorStart
halfTransition.scale(by: 0.5)
let midpoint = (vectorStart + halfTransition).spectrum
precondition(midpoint.input.allSatisfy { $0 == -48 } && midpoint.output.allSatisfy { $0 == -30 }, "RTA display moves between measured spectra without jumping or altering their endpoints")
precondition((EQSpectrumVector.zero + vectorEnd).spectrum == spectrumEnd && (vectorStart + (vectorEnd - vectorStart)).spectrum == spectrumEnd)
print("RTA_TEMPORAL_INTERPOLATION_AND_ENDPOINTS_OK")
