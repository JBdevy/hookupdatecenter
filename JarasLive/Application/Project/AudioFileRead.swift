import AVFoundation

/// Some MP3 gapless headers overstate the final decoded sample count by a
/// fraction of one packet. AVAudioFile then reports EOF (sometimes nilError)
/// after successfully decoding all samples. Other errors remain errors.
enum AudioFileRead {
    private static let mediaLock = NSLock()
    /// Audio-only containers stay on their native decoder. Movie soundtracks
    /// are decoded once into a bounded disk cache, never in the render callback.
    static func openMedia(_ url: URL, cancelled: () -> Bool = { false }) throws -> AVAudioFile {
        if cancelled() { throw CancellationError() }
        try Task.checkCancellation()
        if let file = try? AVAudioFile(forReading: url) { return file }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let rawDescription = track.formatDescriptions.first,
              let source = CMAudioFormatDescriptionGetStreamBasicDescription(rawDescription as! CMAudioFormatDescription)?.pointee else {
            throw NSError(domain: "CatLive.Media", code: 1, userInfo: [NSLocalizedDescriptionKey: "This video has no audio stream."])
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let signature = url.standardizedFileURL.path + "|" + String(describing: attributes[.size]) + "|" + String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        var hash: UInt64 = 14695981039346656037
        for byte in signature.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CatLive-MovieAudio", isDirectory: true)
        let cached = folder.appendingPathComponent(String(hash, radix: 16) + ".caf")
        mediaLock.lock(); defer { mediaLock.unlock() }
        if let file = try? AVAudioFile(forReading: cached) { return file }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let rate = source.mSampleRate, channels = source.mChannelsPerFrame
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw NSError(domain: "CatLive.Media", code: 2) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "CatLive.Media", code: 3) }
        do {
            let writer = try AVAudioFile(forWriting: temporary, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                if cancelled() { throw CancellationError() }
                let count = CMSampleBufferGetNumSamples(sample)
                guard count > 0, let data = CMSampleBufferGetDataBuffer(sample),
                      let buffer = AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: AVAudioFrameCount(count)),
                      let samples = buffer.floatChannelData?[0] else { throw NSError(domain: "CatLive.Media", code: 4) }
                buffer.frameLength = AVAudioFrameCount(count)
                let bytes = count * Int(channels) * MemoryLayout<Float>.size
                guard CMBlockBufferGetDataLength(data) == bytes,
                      CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: bytes, destination: samples) == kCMBlockBufferNoErr else { throw NSError(domain: "CatLive.Media", code: 5) }
                try writer.write(from: buffer)
            }
            guard reader.status == .completed else { throw reader.error ?? NSError(domain: "CatLive.Media", code: 6) }
        } catch { reader.cancelReading(); throw error }
        try FileManager.default.moveItem(at: temporary, to: cached)
        return try AVAudioFile(forReading: cached)
    }
    static func hasMP3Padding(_ file: AVAudioFile) -> Bool {
        let format = file.fileFormat.streamDescription.pointee
        let remaining = file.length - file.framePosition
        return format.mFormatID == kAudioFormatMPEGLayer3 && format.mFramesPerPacket > 0 &&
            file.framePosition > 0 && remaining > 0 && remaining < Int64(format.mFramesPerPacket)
    }
    static func toleratesEnd(_ error: Error, file: AVAudioFile, buffer: AVAudioPCMBuffer) -> Bool {
        let error = error as NSError
        let eof = error.domain == NSOSStatusErrorDomain && error.code == -39
        let decoderEOF = error.domain == "Foundation._GenericObjCError" && error.code == 0
        return (eof || decoderEOF) && buffer.frameLength == 0 && hasMP3Padding(file)
    }
    @discardableResult static func read(_ file: AVAudioFile, into buffer: AVAudioPCMBuffer,
                                       frameCount: AVAudioFrameCount? = nil) throws -> Bool {
        buffer.frameLength = 0
        do { try file.read(into: buffer, frameCount: frameCount ?? buffer.frameCapacity) }
        catch {
            guard toleratesEnd(error, file: file, buffer: buffer) else { throw error }
            return false
        }
        if buffer.frameLength == 0, file.framePosition < file.length, !hasMP3Padding(file) {
            throw NSError(domain: NSOSStatusErrorDomain, code: -39)
        }
        return buffer.frameLength > 0
    }
}
