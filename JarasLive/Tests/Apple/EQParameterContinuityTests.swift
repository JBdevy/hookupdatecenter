import AVFoundation
import AudioToolbox
@testable import JarasApplication

@MainActor private func run() throws {
    for rate in [44100.0, 48000.0, 96000.0] {
        let node = JarasEqualizer.makeNode(), unit = node.auAudioUnit
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        try unit.inputBusses[0].setFormat(format); try unit.outputBusses[0].setFormat(format)
        unit.maximumFramesToRender = 512
        var band = EQBand(frequency: 120); band.gain = 0
        func publish() { JarasEqualizer.configure(node, coefficients: band.coefficients(rate: rate).map { $0.map(NSNumber.init(value:)) }, enabled: true) }
        publish(); try unit.allocateRenderResources()
        defer { unit.deallocateRenderResources() }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        let render = unit.renderBlock
        let pull: AURenderPullInputBlock = { _, _, frames, _, buffers in
            for (ch, buffer) in UnsafeMutableAudioBufferListPointer(buffers).enumerated() {
                buffer.mData!.assumingMemoryBound(to: Float.self).update(repeating: ch == 0 ? 0.05 : -0.025, count: Int(frames))
            }
            return noErr
        }
        var sampleTime = 0, largestError = 0.0, largestStep = 0.0
        var previous = [Double](repeating: 0, count: 2)
        for block in 0..<500 {
            if block >= 100 && block % 4 == 0 {
                let edit = block / 4
                band.gain = edit % 2 == 0 ? 18 : -12
                band.frequency = [55.0, 120, 260, 700][edit % 4]
                band.q = [0.3, 0.707, 2, 8][edit % 4]
                publish()
            }
            output.frameLength = 512
            var flags = AudioUnitRenderActionFlags(), time = AudioTimeStamp()
            time.mSampleTime = Double(sampleTime); time.mFlags = .sampleTimeValid
            precondition(render(&flags, &time, 512, 0, output.mutableAudioBufferList, pull) == noErr)
            for ch in 0..<2 { for n in 0..<512 {
                let value = Double(output.floatChannelData![ch][n])
                precondition(value.isFinite)
                if block >= 100 {
                    largestError = max(largestError, abs(value - (ch == 0 ? 0.05 : -0.025)))
                    largestStep = max(largestStep, abs(value - previous[ch]))
                }
                previous[ch] = value
            } }
            sampleTime += 512
        }
        print("EQ_PARAMETER_CONTINUITY", rate, "unity-DC error", largestError, "largest adjacent step", largestStep)
        if !CommandLine.arguments.contains("--baseline") {
            precondition(largestError < 0.00001 && largestStep < 0.00001,
                "Moving a bell band's gain/frequency/Q must not create an impulse in an unchanged DC signal")
        }
    }
}
try MainActor.assumeIsolated { try run() }
