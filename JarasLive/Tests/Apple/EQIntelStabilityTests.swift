import Foundation
import AVFoundation
import AudioToolbox

// Standalone fixture for test-audio.sh. It intentionally uses no project paths,
// device assumptions, private media, wall-clock deadline or listening judgment.
// An independent direct-form-I reference checks the production transposed-II
// implementation; equivalent block boundaries and analysis must preserve PCM.
private struct ReferenceSection {
    let k: [Double]
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    mutating func tick(_ x: Double) -> Double {
        let y = k[0] * x + k[1] * x1 + k[2] * x2 - k[3] * y1 - k[4] * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

private func reference(_ input: [[Float]], bands: [EQBand], rate: Double) -> [[Float]] {
    let coefficients = bands.flatMap { $0.coefficients(rate: rate) }
    return input.map { channel in
        var sections = coefficients.map { ReferenceSection(k: $0) }
        return channel.map { sample in
            if !sample.isFinite {
                sections = coefficients.map { ReferenceSection(k: $0) }
                return Float(0)
            }
            var value = Double(sample)
            for index in sections.indices { value = sections[index].tick(value) }
            precondition(value.isFinite, "Reference filter became non-finite")
            return Float(value)
        }
    }
}

private func settings(_ bands: [EQBand]) -> NativeFXSettings {
    var result = NativeFXSettings()
    result.inserted = ["EQ"]; result.eqEnabled = true; result.bands = bands
    return result
}

private func reportedBands() -> [EQBand] {
    // An anonymized copy of the saved settings: steep low cut plus three
    // small boosts. The old default-five-section fixture did not cover this.
    var low = EQBand(frequency: 72, type: "lowCut"); low.slope = 72
    var bass = EQBand(frequency: 238); bass.gain = 0.7
    var middle = EQBand(frequency: 1349.4062548068455); middle.gain = 0.2251927948628456
    var presence = EQBand(frequency: 2613); presence.gain = 0.1
    let high = EQBand(frequency: 18000, type: "highCut")
    return [low, bass, middle, presence, high]
}

private func signal(rate: Double, count: Int) -> [[Float]] {
    var result = [[Float](repeating: 0, count: count), [Float](repeating: 0, count: count)]
    var seed: UInt32 = 0x3129a5f7
    for n in 0..<(count - 2048) {
        seed = 1664525 &* seed &+ 1013904223
        let noise = (Double(seed) / Double(UInt32.max) * 2 - 1) * 0.005
        let t = Double(n) / rate
        let value = 0.06 * sin(2 * .pi * 31 * t) + 0.09 * sin(2 * .pi * 997 * t)
                  + 0.04 * sin(2 * .pi * 7300 * t) + noise
        result[0][n] = Float(value)
        result[1][n] = Float(value * 0.55 + 0.03 * sin(2 * .pi * 2011 * t))
    }
    result[0][0] = 0.7; result[1][0] = -0.45
    result[0][1234] -= 0.3; result[1][2345] += 0.2
    return result
}

@MainActor private func render(_ input: [[Float]], settings: NativeFXSettings, rate: Double,
                               blocks: [Int], analysis: Bool = false) throws -> [[Float]] {
    precondition(input.count == 2 && input[0].count == input[1].count)
    let engine = AVAudioEngine(), player = AVAudioPlayerNode(), chain = NativeEffectsChain()
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    engine.attach(player); chain.attach(to: engine, input: player, format: format)
    engine.connect(chain.output, to: engine.mainMixerNode, format: format)
    chain.apply(settings)
    if analysis { chain.observe(["EQ"]) }
    defer { chain.observe([]); engine.stop() }

    // Settle the EQ insertion ramp with silence; reference state then starts
    // at zero. Extra trailing PCM allows the engine's final upstream pull.
    let warmup = 4096, wanted = warmup + input[0].count
    let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(wanted + 4096))!
    source.frameLength = source.frameCapacity
    for ch in 0..<2 {
        source.floatChannelData![ch].initialize(repeating: 0, count: Int(source.frameLength))
        for n in input[ch].indices { source.floatChannelData![ch][warmup + n] = input[ch][n] }
    }
    player.scheduleBuffer(source); try engine.start(); player.play()
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    var result = [[Float](), [Float]()], done = 0, pass = 0, snapshots = 0
    while done < wanted {
        let frames = min(blocks[pass % blocks.count], wanted - done)
        let status = try engine.renderOffline(AVAudioFrameCount(frames), to: output)
        precondition(status == .success && Int(output.frameLength) == frames,
                     "EQ render failure: rate=\(rate), frames=\(frames), status=\(status.rawValue)")
        for ch in 0..<2 {
            let data = UnsafeBufferPointer(start: output.floatChannelData![ch], count: frames)
            precondition(data.allSatisfy(\.isFinite), "EQ produced NaN/Inf PCM")
            result[ch].append(contentsOf: data)
        }
        if analysis, let frame = chain.eqSpectrumFrame() {
            precondition(frame.sampleRate == rate && frame.input?.count == 4096 * MemoryLayout<Float>.size
                         && frame.output?.count == frame.input?.count, "Invalid EQ analysis snapshot")
            snapshots += 1
        }
        done += frames; pass += 1
    }
    if analysis { precondition(snapshots > 0, "Enabled EQ analysis never received PCM") }
    return result.map { Array($0.dropFirst(warmup)) }
}

// Exercise malformed input at the AU boundary itself. Passing NaN/Inf through
// AVAudioPlayerNode/mixers first could sanitize it or contaminate other channels
// before it ever reaches the EQ being tested.
@MainActor private func renderDirect(_ input: [[Float]], coefficients: [[Double]], rate: Double,
                                     blocks: [Int], enabled: Bool = true) throws -> [[Float]] {
    let node = JarasEqualizer.makeNode(), unit = node.auAudioUnit
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    try unit.inputBusses[0].setFormat(format)
    try unit.outputBusses[0].setFormat(format)
    // As the direct AU host, advertise the largest slice before allocation.
    // The full-engine cases above separately cover normal host negotiation.
    unit.maximumFramesToRender = 4096
    JarasEqualizer.configure(node, coefficients: coefficients.map { $0.map(NSNumber.init(value:)) }, enabled: enabled)
    try unit.allocateRenderResources()
    defer { unit.deallocateRenderResources() }
    let renderBlock = unit.renderBlock
    let warmup = 4096, wanted = warmup + input[0].count
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    var cursor = 0
    let pull: AURenderPullInputBlock = { _, _, frames, _, buffers in
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        for ch in 0..<2 {
            guard let pointer = list[ch].mData else { return kAudioUnitErr_InvalidPropertyValue }
            let data = pointer.assumingMemoryBound(to: Float.self)
            for n in 0..<Int(frames) {
                let index = cursor + n - warmup
                data[n] = index >= 0 && index < input[ch].count ? input[ch][index] : 0
            }
        }
        cursor += Int(frames)
        return noErr
    }
    var result = [[Float](), [Float]()], done = 0, pass = 0
    while done < wanted {
        let frames = min(blocks[pass % blocks.count], wanted - done)
        output.frameLength = AVAudioFrameCount(frames)
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        time.mSampleTime = Double(done); time.mFlags = .sampleTimeValid
        let status = renderBlock(&flags, &time, AVAudioFrameCount(frames), 0, output.mutableAudioBufferList, pull)
        precondition(status == noErr, "Direct EQ render failed: \(status)")
        for ch in 0..<2 {
            result[ch].append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![ch], count: frames))
        }
        done += frames; pass += 1
    }
    precondition(cursor == wanted, "EQ failed to pull exactly one input slice per render")
    return result.map { Array($0.dropFirst(warmup)) }
}

private func compareReference(_ actual: [[Float]], _ expected: [[Float]], context: String) {
    for ch in 0..<2 {
        precondition(actual[ch].count == expected[ch].count)
        var maximum = 0.0, power = 0.0, scale = 0.0
        for n in actual[ch].indices {
            let error = Double(actual[ch][n]) - Double(expected[ch][n])
            maximum = max(maximum, abs(error)); power += error * error
            scale = max(scale, abs(Double(expected[ch][n])))
        }
        let rms = sqrt(power / Double(actual[ch].count))
        precondition(maximum <= 0.00001 * max(1, scale) && rms <= 0.000003 * max(1, scale),
                     "EQ unexplained residual: \(context), ch=\(ch), peak=\(maximum), RMS=\(rms)")
    }
}

private func compareExact(_ first: [[Float]], _ second: [[Float]], context: String) {
    for ch in 0..<2 {
        precondition(first[ch].count == second[ch].count)
        precondition(zip(first[ch], second[ch]).allSatisfy { $0.bitPattern == $1.bitPattern },
                     "EQ PCM depends on analysis/block partition: \(context), ch=\(ch)")
    }
}

private func transfer(_ bands: [EQBand], frequency: Double, rate: Double) -> (real: Double, imaginary: Double) {
    let w = 2 * Double.pi * frequency / rate
    var real = 1.0, imaginary = 0.0
    for k in bands.flatMap({ $0.coefficients(rate: rate) }) {
        let nr = k[0] + k[1] * cos(w) + k[2] * cos(2 * w)
        let ni = -k[1] * sin(w) - k[2] * sin(2 * w)
        let dr = 1 + k[3] * cos(w) + k[4] * cos(2 * w)
        let di = -k[3] * sin(w) - k[4] * sin(2 * w), denominator = dr * dr + di * di
        let r = (nr * dr + ni * di) / denominator, i = (ni * dr - nr * di) / denominator
        let next = real * r - imaginary * i
        imaginary = imaginary * r + real * i; real = next
    }
    return (real, imaginary)
}

@MainActor private func runEQIntelStability() throws {
    let varied = [64, 128, 256, 512, 1024, 2048, 4096]
    for rate in [44100.0, 48000.0, 96000.0] {
        let input = signal(rate: rate, count: 16384)
        var cases: [(String, NativeFXSettings)] = [
            ("default", settings(NativeFXSettings().bands)), ("reported-steep-cut", settings(reportedBands()))
        ]
        for kind in ["lowCut", "highCut"] {
            for (index, slope) in [6, 12, 24, 36, 48, 72, 96, 192].enumerated() {
                var band = EQBand(frequency: slope == 192 ? 20 : [20.0, 72.0, 18000.0][index % 3], type: kind)
                band.slope = slope
                cases.append(("\(kind)-\(slope)-\(band.frequency)", settings([band])))
            }
        }
        for kind in ["bell", "lowShelf", "highShelf"] {
            for q in [0.1, 0.707, 18.0] {
                for gain in [-24.0, 24.0] {
                    var band = EQBand(frequency: kind == "bell" ? 1000 : (kind == "lowShelf" ? 72 : 18000), type: kind)
                    band.q = q; band.gain = gain
                    cases.append(("\(kind)-Q\(q)-gain\(gain)", settings([band])))
                }
            }
        }
        for (name, configuration) in cases {
            try configuration.validate()
            let expected = reference(input, bands: configuration.bands, rate: rate)
            let fixed = try render(input, settings: configuration, rate: rate, blocks: [512])
            let partitioned = try render(input, settings: configuration, rate: rate, blocks: varied)
            compareReference(fixed, expected, context: "\(name), rate=\(rate)")
            compareExact(fixed, partitioned, context: "\(name), rate=\(rate)")
            if name == "default" || name == "reported-steep-cut" {
                let observed = try render(input, settings: configuration, rate: rate, blocks: [512], analysis: true)
                compareExact(fixed, observed, context: "RTA \(name), rate=\(rate)")
            }
        }

        // The reported preset also has a high-input-gain native limiter after
        // EQ. Isolate that nonlinear path from the EQ's linear reference.
        var limited = settings(reportedBands())
        limited.inserted.append("Limiter"); limited.limiterEnabled = true
        var limiter = NativeLimiterSettings(); limiter.inputGain = 12.7; limiter.ceiling = -0.1; limiter.release = 0.1
        limited.limiter = limiter
        let limitedClosed = try render(input, settings: limited, rate: rate, blocks: [512])
        let limitedOpen = try render(input, settings: limited, rate: rate, blocks: varied, analysis: true)
        compareExact(limitedClosed, limitedOpen, context: "EQ+Limiter, rate=\(rate)")
        let ceiling = pow(10, limiter.ceiling / 20)
        precondition(limitedClosed.joined().allSatisfy { abs(Double($0)) <= ceiling + 0.000001 },
                     "Reported EQ/limiter chain exceeds its sample ceiling")

        // A fixed tone has a known analytic amplitude and phase. Any sustained
        // added noise/modulation remains in the residual after startup settles.
        let frequency = 997.0, amplitude = 0.1, count = Int(rate * 0.7)
        let tone = (0..<count).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
        let toneOutput = try render([tone, tone.map { -$0 }], settings: settings(reportedBands()), rate: rate, blocks: varied)
        let response = transfer(reportedBands(), frequency: frequency, rate: rate)
        var energy = 0.0, peak = 0.0, measured = 0
        for n in Int(rate * 0.4)..<count {
            let phase = 2 * Double.pi * frequency * Double(n) / rate
            let expected = amplitude * (response.real * sin(phase) + response.imaginary * cos(phase))
            let residual = Double(toneOutput[0][n]) - expected
            energy += residual * residual; peak = max(peak, abs(residual)); measured += 1
            precondition(abs(toneOutput[0][n] + toneOutput[1][n]) < 0.000001,
                         "EQ couples stereo state")
        }
        let rms = sqrt(energy / Double(measured))
        precondition(rms < 0.000003 && peak < 0.00001,
                     "Steady EQ added noise/modulation: rate=\(rate), RMS=\(rms), peak=\(peak)")

        // Defensive recovery is a separate issue from the reported hiss: one
        // bad upstream sample must neither escape nor poison subsequent PCM.
        var invalid = input
        let badPositions = [63, 511, 4095]
        invalid[0][badPositions[0]] = .nan
        invalid[0][badPositions[1]] = .infinity
        invalid[0][badPositions[2]] = -.infinity
        let coefficients = reportedBands().flatMap { $0.coefficients(rate: rate) }
        let recovered = try renderDirect(invalid, coefficients: coefficients, rate: rate, blocks: varied)
        precondition(recovered.joined().allSatisfy(\.isFinite), "Invalid EQ input escaped as NaN/Inf")
        for position in badPositions { precondition(recovered[0][position] == 0, "Invalid EQ input was not contained") }
        compareReference(recovered, reference(invalid, bands: reportedBands(), rate: rate),
                         context: "nonfinite recovery, rate=\(rate)")
        let healthy = try renderDirect(input, coefficients: coefficients, rate: rate, blocks: varied)
        precondition(zip(healthy[1], recovered[1]).allSatisfy { $0.bitPattern == $1.bitPattern },
                     "Nonfinite sample reset the healthy stereo channel")

        // A finite Double result can become Inf when narrowed to Float32.
        // Use a stable feed-forward section to isolate that conversion.
        var overflow = [[Float](repeating: 0.125, count: 8192), [Float](repeating: -0.125, count: 8192)]
        overflow[0][511] = Float.greatestFiniteMagnitude
        overflow[0][4095] = -Float.greatestFiniteMagnitude
        let bounded = try renderDirect(overflow, coefficients: [[2, 0, 0, 0, 0]], rate: rate, blocks: varied)
        for n in overflow[0].indices {
            precondition(bounded[0][n] == (n == 511 || n == 4095 ? 0 : 0.25)
                         && bounded[1][n] == -0.25, "EQ Float32 overflow did not recover immediately")
        }
        let bypassed = try renderDirect(invalid, coefficients: coefficients, rate: rate, blocks: varied, enabled: false)
        precondition(bypassed[0][63].isNaN && bypassed[0][511] == .infinity && bypassed[0][4095] == -.infinity,
                     "Fully bypassed EQ unexpectedly scans/modifies its input")
        print("EQ_STEADY_DFI_ANALYTIC_RTA_PARTITIONS_64_4096_AND_REPORTED_PRESET_OK rate=\(rate) cases=\(cases.count) residualRMS=\(rms)")
        print("EQ_NONFINITE_INPUT_FLOAT32_OVERFLOW_CHANNEL_ISOLATION_AND_RECOVERY_OK rate=\(rate)")
    }
}

try MainActor.assumeIsolated { try runEQIntelStability() }
