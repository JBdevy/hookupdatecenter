import Foundation
import AVFoundation
@MainActor func render(_ settings: NativeFXSettings, rate: Double, frequency: Double? = 1000, duration: Double = 1) throws -> [[Float]] {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let player = AVAudioPlayerNode(), chain = NativeEffectsChain()
    engine.attach(player)
    chain.attach(to: engine, input: player, format: format)
    engine.connect(chain.output, to: engine.mainMixerNode, format: format)
    chain.apply(settings)
    chain.observe(["Delay","Reverb"])
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
    precondition(chain.spectrum("Reverb")?.count == 4096*MemoryLayout<Float>.size, "reverb spectrum receives stereo PCM")
    precondition(chain.spectrum("Delay")?.count == 4096*MemoryLayout<Float>.size, "delay spectrum receives its own output")
    chain.observe([])
    precondition(chain.spectrum("Reverb") == nil, "closing editor stops analysis")
    let meters = chain.compressorPeaks()
    if settings.compressorEnabled { precondition(meters[0] > meters[2] && meters[1] > meters[3], "compressor meters read its own input and output") }
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
    for _ in 0..<8 {
        let silence = try render()
        precondition(silence == 0, "sleeping output remains digitally silent")
    }
    precondition(sourcePulls == before, "sleeping route must not pull the upstream track and effects")
    JarasChannelRouter.setRenderEnabled(route, enabled: true)
    let restored = try render()
    precondition(restored > 0.1 && sourcePulls > before, "waking route immediately restores audio")
    engine.stop()
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
@MainActor func run() throws {
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
try MainActor.assumeIsolated { try run() }

let spectrumStart = EQSpectrum(input: Array(repeating: -72, count: EQSpectrum.binCount), output: Array(repeating: -48, count: EQSpectrum.binCount))
let spectrumEnd = EQSpectrum(input: Array(repeating: -24, count: EQSpectrum.binCount), output: Array(repeating: -12, count: EQSpectrum.binCount))
let vectorStart = EQSpectrumVector(spectrumStart), vectorEnd = EQSpectrumVector(spectrumEnd)
var halfTransition = vectorEnd - vectorStart
halfTransition.scale(by: 0.5)
let midpoint = (vectorStart + halfTransition).spectrum
precondition(midpoint.input.allSatisfy { $0 == -48 } && midpoint.output.allSatisfy { $0 == -30 }, "RTA display moves between measured spectra without jumping or altering their endpoints")
precondition((EQSpectrumVector.zero + vectorEnd).spectrum == spectrumEnd && (vectorStart + (vectorEnd - vectorStart)).spectrum == spectrumEnd)
print("RTA_TEMPORAL_INTERPOLATION_AND_ENDPOINTS_OK")
