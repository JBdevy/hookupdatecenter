import Foundation
import AVFoundation
import Darwin

// The fixture encodes its VST3 tempo context into gain. Non-block-aligned
// markers and distinct item-export origins catch stale tempo and wrong clocks.
AudioLicenseAccess.shared.setAllowed(true)
setenv("CATLIVE_TEST_VST3_TEMPO_GAIN", "1", 1)
defer { unsetenv("CATLIVE_TEST_VST3_TEMPO_GAIN") }
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let rate = 48000.0, format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
let path = ProcessInfo.processInfo.environment["JARAS_TEST_VST3"]!
var scanError: NSError?
let scan = JarasVST3.scan(path, error: &scanError)
precondition(scanError == nil && scan.count == 1)
var plugin = ExternalPlugin(classID: scan[0]["classID"] as! String, name: "Tempo context fixture", path: path)
var unity: Float = 1
plugin.componentState = withUnsafeBytes(of: &unity) { Data($0).base64EncodedString() }
var fx = NativeFXSettings(); fx.externalPlugins = [plugin]; fx.inserted = [plugin.effectKey]
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
buffer.frameLength = buffer.frameCapacity
for channel in 0..<2 { for frame in 0..<48000 { buffer.floatChannelData![channel][frame] = 0.125 } }
do { let file = try AVAudioFile(forWriting: root.appendingPathComponent("constant.wav"), settings: format.settings); try file.write(from: buffer) }
var project = Project.empty(name: "Tempo context")
project.songs[0].bpm = 120; project.songs[0].duration = 1.5
project.songs[0].timeSettings = ProjectTimeSettings(); project.songs[0].timeSettings?.timebase = .free
project.songs[0].markers = [
    TimelineMarker(id: UUID(), name: "Slow", position: 0.3, color: 0, tempoBPM: 60, tempoTimebase: .free),
    TimelineMarker(id: UUID(), name: "Fast", position: 0.73125, color: 0, tempoBPM: 180, tempoTimebase: .free)
]
for index in 0..<2 {
    var track = Track(id: UUID(), name: "Track \(index)", role: .other)
    track.outputs = [.master]; track.fx = fx
    var clip = AudioClip(id: UUID(), name: "Item \(index)", startTime: Double(index) * 0.175, duration: 1, audioFile: AudioFile(path: "constant.wav"))
    clip.fx = fx; track.clips = [clip]; project.songs[0].tracks.append(track)
}
let tracks = project.songs[0].tracks.filter { !$0.clips.isEmpty }
project.songs[0].tracks = tracks
let jobs = tracks.enumerated().map { index, track in
    AudioExportJob(id: "item\(index)", fileName: "item\(index).wav", start: track.clips[0].startTime,
        end: track.clips[0].startTime + 1, track: track.id, clip: track.clips[0].id)
}
try OfflineAudioExport.run(project: project, song: project.songs[0], plan: AudioExportPlan(jobs: jobs),
    mediaDirectory: root, outputDirectory: root.appendingPathComponent("out"), sampleRate: rate,
    encoding: AudioExportEncoding(bitDepth: 32), cancellation: AudioExportCancellation()) { _ in }
for job in jobs {
    let file = try AVAudioFile(forReading: root.appendingPathComponent("out").appendingPathComponent(job.fileName))
    let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: pcm)
    precondition(pcm.frameLength == 48000)
    for frame in 0..<48000 {
        let position = job.start + Double(frame) / rate
        let multiplier: Float = position < 0.3 ? 1 : position < 0.73125 ? 0.5 : 1.5
        let expected = 0.125 * multiplier * multiplier
        for channel in 0..<2 {
            precondition(abs(pcm.floatChannelData![channel][frame] - expected) < 0.00001,
                "VST3 tempo context must change at marker sample: \(job.id) frame \(frame)")
        }
    }
}
print("OFFLINE_ITEM_AND_TRACK_VST3_TEMPO_CONTEXT_EXACT_BOUNDARIES_AND_INDEPENDENT_ORIGINS_OK")
