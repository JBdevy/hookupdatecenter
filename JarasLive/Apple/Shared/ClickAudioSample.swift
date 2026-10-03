import AVFoundation

/// The bundled one-shot is decoded once per audio graph, outside the render callback.
enum ClickAudioSample {
    static func load(sampleRate: Double, url: URL? = nil) throws -> Data {
        guard let url = url ?? Bundle.main.url(forResource: "Click", withExtension: "mp3") else {
            throw ProjectError.invalid("Click audio is missing from the application")
        }
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.length < AVAudioFramePosition(UInt32.max),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(file.length) * sampleRate / file.processingFormat.sampleRate)) + 256) else {
            throw ProjectError.invalid("Unable to load Click audio")
        }
        try file.read(into: input)
        converter.downmix = true
        var supplied = false; var failure: NSError?
        let result = converter.convert(to: output, error: &failure) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if let failure { throw failure }
        guard result != .error, let samples = output.floatChannelData?[0], output.frameLength > 0 else {
            throw ProjectError.invalid("Unable to load Click audio")
        }
        // Exclude trailing silence without moving or normalizing the original attack.
        var end = Int(output.frameLength)
        while end > 1 && abs(samples[end - 1]) < 0.000001 { end -= 1 }
        end = min(Int(output.frameLength), end + Int(sampleRate * 0.01))
        return Data(bytes: samples, count: end * MemoryLayout<Float>.size)
    }
}
