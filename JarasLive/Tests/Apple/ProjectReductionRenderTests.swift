import Foundation
import AVFoundation
final class ReductionProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProjectReductionProgress] = []
    func append(_ event: ProjectReductionProgress) { lock.lock(); defer { lock.unlock() }; events.append(event) }
    var values: [ProjectReductionProgress] { lock.lock(); defer { lock.unlock() }; return events }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000)!
buffer.frameLength = 192000
for ch in 0..<2 { for n in 0..<192000 { buffer.floatChannelData![ch][n] = 0.1 } }
var file: AVAudioFile? = try AVAudioFile(forWriting: root.appendingPathComponent("input.wav"), settings: format.settings)
try file!.write(from: buffer); file = nil
var project = Project.empty(name: "Original")
var a = Track(id: UUID(), name: "A", role: .other); a.volume = 0.5
var b = Track(id: UUID(), name: "B", role: .other)
let unrelated = Track(id: UUID(), name: "Unselected", role: .other)
a.clips = [AudioClip(id: UUID(), name: "A", startTime: 0, duration: 4, audioFile: AudioFile(path: "input.wav"))]
b.clips = [AudioClip(id: UUID(), name: "B", startTime: 0, duration: 4.000000000002, audioFile: AudioFile(path: "input.wav"))]
project.songs[0].tracks = [a,b,unrelated]
project.songs[0].parts = [Part(id: UUID(), name: "One", startTime: 0, endTime: 2), Part(id: UUID(), name: "Two", startTime: 2, endTime: 4)]
project.masterVolume = 0.7
let group = ProjectReductionTrack(name: "Mixed", sources: [a.id,b.id])
let target = root.appendingPathComponent("Reduced/Reduced.jl")
let progressLog = ReductionProgressLog()
try ReducedProjectWriter.write(project: project, groups: [group], media: root, target: target, instruments: [:], cancellation: AudioExportCancellation()) { progressLog.append($0) }
let events = progressLog.values
precondition(events.first?.fraction == 0 && events.last?.fraction == 1)
precondition(zip(events, events.dropFirst()).allSatisfy { $0.fraction <= $1.fraction }, "Reduction progress moved backwards between regions")
precondition(events.dropLast().allSatisfy { $0.fraction < 1 }, "Progress finished before the project was saved")
precondition(events.contains { $0.message.contains("Mixed") && $0.message.contains("One") })
precondition(events.contains { $0.message.contains("Mixed") && $0.message.contains("Two") })
precondition(events.contains { $0.message.contains("Salvando projeto") })
let result = try ProjectDocumentCodec.decode(Data(contentsOf: target))
precondition(result.songs[0].tracks.count == 1)
let clips = result.songs[0].tracks[0].clips
precondition(clips.count == 2 && clips.map(\.startTime) == [0,2] && clips.map(\.duration) == [2,2])
precondition(result.masterVolume == 0.7 && result.id != project.id && result.projectSyncID != project.projectSyncID)
for clip in clips {
    let wave = try AVAudioFile(forReading: target.deletingLastPathComponent().appendingPathComponent(clip.audioFile!.path))
    precondition(wave.length == 96000)
    let pcm = AVAudioPCMBuffer(pcmFormat: wave.processingFormat, frameCapacity: 512)!
    wave.framePosition = 12000; try wave.read(into: pcm)
    precondition(abs(pcm.floatChannelData![0][100] - 0.15) < 0.001, "Rendered volume differs from the original mix")
}
var rejected = false
do { try ReducedProjectWriter.write(project: project, groups: [group], media: root, target: target, instruments: [:], cancellation: AudioExportCancellation()) { _ in } } catch { rejected = true }
precondition(rejected && FileManager.default.fileExists(atPath: target.path))
let cancellation = AudioExportCancellation(); cancellation.cancel()
let cancelled = root.appendingPathComponent("Cancelled/Cancelled.jl")
do { try ReducedProjectWriter.write(project: project, groups: [group], media: root, target: cancelled, instruments: [:], cancellation: cancellation) { _ in } } catch {}
precondition(!FileManager.default.fileExists(atPath: cancelled.deletingLastPathComponent().path))
precondition(project.songs[0].tracks.count == 3)
// A single selected source keeps editable clips and processing unchanged.
let singleTarget = root.appendingPathComponent("Single/Single.jl")
try ReducedProjectWriter.write(project: project, groups: [ProjectReductionTrack(name: "Renamed", sources: [a.id])], media: root, target: singleTarget, instruments: [:], cancellation: AudioExportCancellation()) { _ in }
let single = try ProjectDocumentCodec.decode(Data(contentsOf: singleTarget))
precondition(single.songs[0].tracks.count == 1 && single.songs[0].tracks[0].clips == a.clips && single.songs[0].tracks[0].volume == a.volume)
precondition(FileManager.default.fileExists(atPath: singleTarget.deletingLastPathComponent().appendingPathComponent("input.wav").path))
// Track polarity and insert gain are printed once, while Master stays live.
project.songs[0].tracks[0].phaseInverted = true
var fx = NativeFXSettings(); fx.compressorEnabled = true; fx.ratio = 1; fx.threshold = 0; fx.makeup = 6
project.songs[0].tracks[1].fx = fx
let fxTarget = root.appendingPathComponent("FX/FX.jl")
try ReducedProjectWriter.write(project: project, groups: [group], media: root, target: fxTarget, instruments: [:], cancellation: AudioExportCancellation()) { _ in }
let processed = try ProjectDocumentCodec.decode(Data(contentsOf: fxTarget))
let fxWave = try AVAudioFile(forReading: fxTarget.deletingLastPathComponent().appendingPathComponent(processed.songs[0].tracks[0].clips[0].audioFile!.path))
let fxPCM = AVAudioPCMBuffer(pcmFormat: fxWave.processingFormat, frameCapacity: 512)!
fxWave.framePosition = 12000; try fxWave.read(into: fxPCM)
precondition(abs(fxPCM.floatChannelData![0][100] - Float(-0.05 + 0.1 * pow(10, 6.0/20))) < 0.001, "FX or polarity changed")
// Flatten nested folders, including the one-source path: group processing
// belongs in the rendered PCM, never in extra destination tracks.
var outer = Track(id: UUID(), name: "Outer", role: .other); outer.volume = 0.5; outer.fx = fx
var inner = Track(id: UUID(), name: "Inner", role: .other); inner.volume = 0.5; inner.parentTrackID = outer.id
var groupedA = a; groupedA.parentTrackID = inner.id
var groupedB = b; groupedB.parentTrackID = inner.id
project.songs[0].tracks = [outer, inner, groupedA, groupedB, unrelated]
for (name, sources, dry) in [("FlatMix", Set([a.id,b.id]), 0.15), ("FlatSingle", Set([a.id]), 0.05)] {
    let flatTarget = root.appendingPathComponent("\(name)/\(name).jl")
    try ReducedProjectWriter.write(project: project, groups: [ProjectReductionTrack(name: name, sources: sources)], media: root, target: flatTarget, instruments: [:], cancellation: AudioExportCancellation()) { _ in }
    let flat = try ProjectDocumentCodec.decode(Data(contentsOf: flatTarget))
    precondition(flat.songs[0].tracks.count == 1 && flat.songs[0].tracks[0].name == name)
    let destination = flat.songs[0].tracks[0]
    precondition(destination.parentTrackID == nil && destination.volume == 1 && destination.clips.count == 2)
    let wave = try AVAudioFile(forReading: flatTarget.deletingLastPathComponent().appendingPathComponent(destination.clips[0].audioFile!.path))
    let pcm = AVAudioPCMBuffer(pcmFormat: wave.processingFormat, frameCapacity: 512)!
    wave.framePosition = 12000; try wave.read(into: pcm)
    precondition(abs(pcm.floatChannelData![0][100] - Float(dry * 0.25 * pow(10,6.0/20))) < 0.001, "Ancestor gain/FX lost or applied twice")
}
print("Reduction render: PCM gain, region boundaries, selected tracks, destination protection and cancellation passed")

// All advertised formats must contain decodable audio and match the size preview.
for ch in 0..<2 { for n in 0..<192000 { buffer.floatChannelData![ch][n] = 0.1 * sin(Float(n) * 2 * .pi * 440 / 48000) } }
file = try AVAudioFile(forWriting: root.appendingPathComponent("input.wav"), settings: format.settings)
try file!.write(from: buffer); file = nil
project.songs[0].tracks = [a,b]
let size = ProjectReduction.estimate([group], project: project) { _ in 0 }
for outputFormat in AudioExportFormat.allCases {
    let destination = root.appendingPathComponent("Format-\(outputFormat.rawValue)/Test.jl")
    try ReducedProjectWriter.write(project: project, groups: [group], media: root, target: destination, instruments: [:], cancellation: AudioExportCancellation(), format: outputFormat) { _ in }
    let output = try ProjectDocumentCodec.decode(Data(contentsOf: destination))
    var actualBytes = Double(try Data(contentsOf: destination).count)
    for clip in output.songs[0].tracks[0].clips {
        let url = destination.deletingLastPathComponent().appendingPathComponent(clip.audioFile!.path)
        precondition(url.pathExtension == outputFormat.fileExtension)
        actualBytes += Double(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
        let reader = try AVAudioFile(forReading: url)
        precondition(abs(Double(reader.length) / reader.processingFormat.sampleRate - clip.duration) < 0.1)
        let pcm = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 4096)!
        reader.framePosition = 12000; try reader.read(into: pcm)
        let peak = (0..<Int(pcm.frameLength)).map { abs(pcm.floatChannelData![0][$0]) }.max()!
        precondition(abs(peak - 0.15) < 0.01, "Encoding changed the rendered gain")
    }
    precondition(actualBytes <= size.bytes(for: outputFormat) * 1.05, "Size preview underestimates rendered output")
    print("REDUCTION_FORMAT_OK", outputFormat.rawValue, "bytes", actualBytes, "estimate", size.bytes(for: outputFormat))
}

let noSpaceTarget = root.appendingPathComponent("FullDisk/FullDisk.jl")
let noSpaceProgress = ReductionProgressLog()
var rejectedBeforeRendering = false
do {
    try ReducedProjectWriter.write(project: project, groups: [group], media: root, target: noSpaceTarget, instruments: [:], cancellation: AudioExportCancellation(), availableCapacity: { _ in 0 }) { noSpaceProgress.append($0) }
} catch {
    rejectedBeforeRendering = error.localizedDescription.contains("Espaço insuficiente") && error.localizedDescription.contains("disponível")
}
precondition(rejectedBeforeRendering && !FileManager.default.fileExists(atPath: noSpaceTarget.deletingLastPathComponent().path))
precondition(!noSpaceProgress.values.contains { $0.message.contains("Renderizando") })
print("REDUCTION_FULL_DISK_REJECTED_BEFORE_RENDER_OK")
