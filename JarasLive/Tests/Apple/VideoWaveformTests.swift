import AppKit
import AVFoundation
import SwiftUI
setbuf(stdout, nil)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-video-waveform-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
pcm.frameLength = 48000
for channel in 0..<2 { for frame in 0..<48000 { pcm.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48000) * 0.4) } }
do { let audio = try AVAudioFile(forWriting: temporary.appendingPathComponent("stereo-48000.wav"), settings: format.settings); try audio.write(from: pcm) }
let cache = TimelineAudioWaveform.shared
func waitFor<T>(_ work: () -> T?) -> T {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline { if let value = work() { return value }; RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    fatalError("Waveform preparation timed out")
}
// Movie containers must use the same soundtrack decoder as playback, including
// after a video enters the project without embedded overview peaks.
do {
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
    for (ext, type) in [("mov", AVFileType.mov), ("mp4", AVFileType.mp4)] {
        let composition = AVMutableComposition()
        let movie = AVURLAsset(url: silent)
        let audio = AVURLAsset(url: temporary.appendingPathComponent("stereo-48000.wav"))
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
        let header = waitFor { cache.header(url) }
        precondition(header.frames > 0 && header.channels > 0)
        let peaks = waitFor { cache.geometry(url, header: header, block: 0, pixelsPerSecond: header.rate / 1024) }
        precondition(peaks.paths.contains { $0.boundingRect.height > 0.1 }, "Video soundtrack waveform is empty")
        print("VIDEO_SOUNDTRACK_WAVEFORM_OK \(ext)")
    }
    do { _ = try AudioFileRead.openMedia(silent); preconditionFailure("Silent movie must not invent an audio stream") }
    catch { precondition(AudioFileRead.isVideoWithoutAudio(error)) }
}
