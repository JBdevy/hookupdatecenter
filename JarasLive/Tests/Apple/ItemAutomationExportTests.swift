import Foundation
import AVFoundation
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let rate = 48000.0, format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240000)!; tone.frameLength = tone.frameCapacity
for channel in 0..<2 { for index in 0..<Int(tone.frameLength) { tone.floatChannelData![channel][index] = Float(0.02 * sin(2 * Double.pi * 440 * Double(index) / rate)) } }
do { let file = try AVAudioFile(forWriting: root.appendingPathComponent("tone.wav"), settings: format.settings); try file.write(from: tone) }
func envelope(_ kind: AutomationTarget.Kind, _ points: [(Double,Double)]) -> TrackAutomation {
    var result = TrackAutomation(); result.mode = .read
    var curve = TrackEnvelope(target: AutomationTarget(kind), name: "Test", defaultValue: 0.5)
    curve.points = points.map { .init(time: $0.0, value: kind == .volume ? TrackEnvelope.normalizedGain($0.1) : $0.1, shape: .square) }
    result.envelopes = [curve]; return result
}
func samples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: pcm)
    return Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
}
func rms(_ samples: [Float], _ time: Double) -> Double {
    let start = Int(time * rate), count = 4800
    return sqrt(samples[start..<start+count].reduce(0) { $0 + Double($1*$1) } / Double(count))
}
var project = Project.empty(name: "Export take envelopes")
var track = Track(id: UUID(), name: "Take track", role: .other)
var clip = AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 4, sourceOffset: 0.5,
                     audioFile: AudioFile(path: "tone.wav"), gain: 0.8, playbackRate: 0.5)
clip.automation = envelope(.volume, [(0.5,1),(1.5,0.25)])
track.clips = [clip]; track.automation = envelope(.volume, [(0,1),(1,0.5)])
project.songs[0].tracks = [track]; project.masterAutomation = envelope(.volume, [(0,1),(3,0.5)])
func render(_ project: Project, _ name: String) throws -> [Float] {
    let job = AudioExportJob(id: name, fileName: name + ".wav", start: 0, end: 4, track: nil, clip: nil)
    let folder = root.appendingPathComponent(name)
    try OfflineAudioExport.run(project: project, song: project.songs[0], plan: AudioExportPlan(jobs: [job]), mediaDirectory: root,
        outputDirectory: folder, sampleRate: rate, cancellation: AudioExportCancellation()) { _ in }
    return try samples(folder.appendingPathComponent(job.fileName))
}
let combined = try render(project, "combined")
precondition(abs(rms(combined,0.5)/rms(combined,1.5)-2)<0.03, "Track automation must reach exported Master PCM")
precondition(abs(rms(combined,1.5)/rms(combined,2.5)-4)<0.03, "Take envelope must use its source offset and playback rate during export")
precondition(abs(rms(combined,2.5)/rms(combined,3.5)-2)<0.03, "Master automation must reach exported PCM")
let frozen = try ItemReRender.render(project: project, song: project.songs[0], track: track, clip: clip, directory: root,
    settings: MediaProcessingFormat(format: .wav, bitDepth: 24, bitrate: 320), cancellation: AudioExportCancellation())
precondition(frozen.automation == nil && frozen.automationSourceOffset == nil, "Printed take automation must be cleared")
let frozenPCM = try samples(root.appendingPathComponent(frozen.audioFile!.path))
precondition(abs(rms(frozenPCM,0.5)/rms(frozenPCM,1.5)-1)<0.03, "Item rerender must leave track automation live")
precondition(abs(rms(frozenPCM,0.5)/rms(frozenPCM,2.5)-4)<0.03, "Item rerender must bake take automation")
let replacements = try ItemReRender.glueSelection(project: project, song: project.songs[0], ids: [clip.id], directory: root, cancellation: AudioExportCancellation())
precondition(replacements.count == 1)
precondition(replacements[0].rendered.automation == nil && replacements[0].rendered.automationSourceOffset == nil, "Glue must clear baked automation")
let gluedPCM = try samples(root.appendingPathComponent(replacements[0].rendered.audioFile!.path))
precondition(abs(rms(gluedPCM,0.5)/rms(gluedPCM,2.5)-4)<0.03, "Glue must print the take envelope")
print("OFFLINE_TAKE_TRACK_MASTER_AUTOMATION_AND_RERENDER_BAKE_RESET_PCM_OK")
if let path = ProcessInfo.processInfo.environment["JARAS_TEST_VST3"] {
    var error: NSError?
    let descriptor = JarasVST3.scan(path, error: &error)[0]
    let plugin = ExternalPlugin(classID: descriptor["classID"] as! String, name: "Gain fixture", path: path)
    var fx = NativeFXSettings(); fx.inserted = [plugin.effectKey]; fx.externalPlugins = [plugin]
    var parameter = TrackEnvelope(target: AutomationTarget(.externalFX, plugin: plugin.id, parameter: 0), name: "Take VST3 gain", defaultValue: 0.5)
    parameter.points = [.init(time: 0.5, value: 0.8, shape: .square), .init(time: 1.5, value: 0.2, shape: .square)]
    clip.fx = fx; clip.automation?.envelopes = [parameter]
    track.automation = nil; track.clips = [clip]; project.songs[0].tracks = [track]; project.masterAutomation = nil
    let output = try render(project, "external")
    precondition(abs(rms(output,0.5)/rms(output,2.5)-4)<0.05, "Imported take VST3 automation must print into offline PCM")
    print("OFFLINE_EXTERNAL_TAKE_AUTOMATION_PCM_OK")
}
