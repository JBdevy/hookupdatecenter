import AVFoundation

/// The MOV is loud in its first half and the MP4 in its second half.
func makeWaveformMovies(in temporary: URL) throws -> (movies: [URL], silent: URL) {
    let silent = temporary.appendingPathComponent("silent-waveform.mov")
    let writer = try AVAssetWriter(outputURL: silent, fileType: .mov)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
    writer.add(video); precondition(writer.startWriting()); writer.startSession(atSourceTime: .zero)
    var pixel: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    for frame in 0..<5 {
        let deadline = Date().addingTimeInterval(10)
        while !video.isReadyForMoreMediaData && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
        precondition(adaptor.append(pixel!, withPresentationTime: CMTime(value: Int64(frame), timescale: 5)))
    }
    video.markAsFinished()
    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting { finished.signal() }
    precondition(finished.wait(timeout: .now() + 15) == .success && writer.status == .completed)
    var movies: [URL] = []
    for (index, type) in [AVFileType.mov, .mp4].enumerated() {
        let ext = index == 0 ? "mov" : "mp4"
        let sound = temporary.appendingPathComponent("sound-\(index).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        pcm.frameLength = pcm.frameCapacity
        for frame in 0..<Int(pcm.frameLength) {
            let loud = index == 0 ? frame < 19000 : frame >= 19000
            let sample = Float(sin(Double(frame) * 2 * .pi * 440 / 48000)) * (loud ? 0.7 : 0.05)
            for channel in 0..<2 { pcm.floatChannelData![channel][frame] = sample }
        }
        do {
            let file = try AVAudioFile(forWriting: sound, settings: format.settings)
            try file.write(from: pcm)
        }
        let composition = AVMutableComposition()
        let movie = AVURLAsset(url: silent)
        let audio = AVURLAsset(url: sound)
        let duration = CMTime(seconds: 0.8, preferredTimescale: 48000)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: movie.tracks(withMediaType: .video)[0], at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audio.tracks(withMediaType: .audio)[0], at: .zero)
        let url = temporary.appendingPathComponent("soundtrack.\(ext)")
        let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        export.outputURL = url; export.outputFileType = type
        let exported = DispatchSemaphore(value: 0)
        export.exportAsynchronously { exported.signal() }
        let deadline = Date().addingTimeInterval(20)
        while exported.wait(timeout: .now()) != .success {
            precondition(Date() < deadline, "Video fixture export timed out")
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        precondition(export.status == .completed, "Video fixture export failed: \(String(describing: export.error))")
        movies.append(url)
    }
    return (movies, silent)
}
