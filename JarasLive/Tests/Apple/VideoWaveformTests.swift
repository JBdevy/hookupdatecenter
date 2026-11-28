import AppKit
import AVFoundation
import SwiftUI
setbuf(stdout, nil)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-video-waveform-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let cache = TimelineAudioWaveform.shared
func waitFor<T>(_ work: () -> T?) -> T {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline { if let value = work() { return value }; RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    fatalError("Waveform preparation timed out")
}
// Movie containers must use the same soundtrack decoder as playback, including
// after a video enters the project without embedded overview peaks.
let fixture = try makeWaveformMovies(in: temporary)
for url in fixture.movies {
    let header = waitFor { cache.header(url) }
    precondition(header.frames > 0 && header.channels > 0)
    let peaks = waitFor { cache.geometry(url, header: header, block: 0, pixelsPerSecond: header.rate / 1024) }
    precondition(peaks.paths.contains { $0.boundingRect.height > 0.1 }, "Video soundtrack waveform is empty")
    print("VIDEO_SOUNDTRACK_WAVEFORM_OK \(url.pathExtension)")
}
do {
    _ = try AudioFileRead.openMedia(fixture.silent)
    preconditionFailure("Silent movie must not invent an audio stream")
} catch { precondition(AudioFileRead.isVideoWithoutAudio(error)) }
