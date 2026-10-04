import Foundation
import AVFoundation
import Darwin

@main struct CatStemRegression {
@MainActor static func main() async throws {
setbuf(stdout, nil)
let root = FileManager.default.temporaryDirectory.appendingPathComponent("catstem-regression-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
do {
    let file = try AVAudioFile(forWriting: root.appendingPathComponent("source.wav"), settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
    buffer.frameLength = 44100
    for channel in 0..<2 { for sample in 0..<44100 {
        buffer.floatChannelData![channel][sample] = 0.15 * sin(Float(sample) * (channel == 0 ? 0.04 : 0.06))
    } }
    try file.write(from: buffer)
}
var project = Project.empty(name: "Separation regression")
let clip = AudioClip(id: UUID(), name: "Source", startTime: 2, duration: 0.75, sourceOffset: 0.125, audioFile: AudioFile(path: "source.wav"))
var track = Track(id: UUID(), name: "Original", role: .other)
track.clips = [clip]; project.songs[0].tracks = [track]
let request = CatStemRequest(project: project, song: project.songs[0], track: track, clip: clip, directory: root)
let resources = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CATLIVE_TEST_RESOURCES"] ?? (NSHomeDirectory() + "/Applications/CatLive.app/Contents/Resources"))
let runtime = resources.appendingPathComponent("StemSeparationRuntime")
let worker = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Apple/Resources/StemSeparation/separate.py")
@MainActor final class RunState {
    var done = false
    var ticks = 0
}
let state = RunState()
do {
    // Exercise the actual meter timer on the main run loop while offline work runs.
    let playback = StemAudioPlayback(engine: AVAudioEngine())
    do {
        try playback.startDeviceSession()
        let heartbeat = Timer(timeInterval: 0.01, repeats: true) { _ in
            Task { @MainActor in state.ticks += 1 }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        defer { heartbeat.invalidate(); playback.prepareForClosing() }
        let original = project
        let (_, tracks) = try await Task.detached {
            try CatStemRenderer.run(request, runtime: runtime, worker: worker, cancellation: AudioExportCancellation()) { fraction, message in
                print(String(format: "%.0f%% %@", fraction * 100, message))
            }
        }.value
        precondition(tracks.count == 5)
        for stem in tracks {
            let item = stem.clips[0]
            precondition(item.startTime == clip.startTime && item.duration == clip.duration)
            let file = try AVAudioFile(forReading: root.appendingPathComponent(item.audioFile!.path))
            precondition(file.length == 33075 && file.processingFormat.channelCount == 2)
        }
        precondition(project == original, "Worker cannot mutate original project")
        try project.insertSeparatedStems(tracks, song: request.song.id, sourceTrack: track.id, original: clip)
        precondition(project.songs[0].tracks.count == 6 && project.songs[0].tracks[0].clips[0].muted == true)
        precondition(state.ticks > 10, "UI run loop must keep responding throughout separation")
        let cancellation = AudioExportCancellation(); cancellation.cancel()
        do {
            _ = try CatStemRenderer.run(request, runtime: runtime, worker: worker, cancellation: cancellation) { _, _ in }
            fatalError("Cancellation was ignored")
        } catch is CancellationError {}
        let outputFolders = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Stems").path)
        precondition(outputFolders.count == 1, "Cancelled work leaves no partial stems")
        print("CATSTEM_REAL_MODEL_FIVE_STEMS_ORIGINAL_PRESERVED_METERS_RESPONSIVE_AND_CANCEL_OK")
        state.done = true
    } catch { playback.prepareForClosing(); print("FAILED: \(error)"); exit(1) }
}

}
}
