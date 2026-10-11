import Foundation
import AVFoundation

// Amplitude bands identify source positions even when time stretching preserves
// pitch. Assertions inspect actual printed PCM, not just the rate metadata.
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let sampleRate = 48000.0
let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
let signal = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480000)!
signal.frameLength = signal.frameCapacity
for channel in 0..<2 {
    for frame in 0..<Int(signal.frameLength) {
        let time = Double(frame) / sampleRate
        let amplitude = time < 2 ? 0.025 : (time < 4 ? 0.1 : 0.04)
        signal.floatChannelData![channel][frame] = Float(amplitude * sin(2 * .pi * 440 * time))
    }
}
do {
    let file = try AVAudioFile(forWriting: root.appendingPathComponent("bands.wav"), settings: format.settings)
    try file.write(from: signal)
}
func samples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: pcm)
    return Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
}
func rms(_ pcm: [Float], _ time: Double) -> Double {
    let start = Int(time * sampleRate), count = 4800
    return sqrt(pcm[start..<start + count].reduce(0) { $0 + Double($1 * $1) } / Double(count))
}
func frequency(_ pcm: [Float], _ time: Double) -> Double {
    let start = Int(time * sampleRate), count = 12000
    let crossings = (start + 1..<start + count).filter { pcm[$0 - 1] <= 0 && pcm[$0] > 0 }.count
    return Double(crossings) * sampleRate / Double(count)
}
let encoding = MediaProcessingFormat(format: .wav, bitDepth: 24, bitrate: 320)
for variable in [false, true] {
    var project = Project.empty(name: "Bake item tempo")
    var song = project.songs[0]
    song.bpm = 120; song.duration = 12
    var owner = Part(id: UUID(), name: "Owner", startTime: 2, endTime: 5)
    let foreign = Part(id: UUID(), name: "Next song", startTime: 5, endTime: 12)
    song.parts = [owner, foreign]
    let clip = AudioClip(id: UUID(), name: "Source", startTime: 2, duration: 4,
        sourceOffset: 0.5, audioFile: AudioFile(path: "bands.wav"), gain: 0.8, regionOwnerID: owner.id)
    var track = Track(id: UUID(), name: "Stem", role: .other)
    owner.pitchSemitones = 12; owner.pitchTrackIDs = [track.id]
    song.parts = [owner, foreign]
    track.volume = 0.3; track.clips = [clip]
    song.tracks = [track]
    song.markers = [
        TimelineMarker(id: UUID(), name: "Owner tempo", position: 2, color: 0, regionOwnerID: owner.id,
            tempoBPM: 180, tempoTimebase: .relative, tempoReferenceBPM: 120),
        TimelineMarker(id: UUID(), name: "Foreign tempo", position: 5, color: 0, regionOwnerID: foreign.id,
            tempoBPM: 240, tempoTimebase: .relative, tempoReferenceBPM: 120)
    ]
    if variable {
        song.markers!.append(TimelineMarker(id: UUID(), name: "Owner change", position: 4, color: 0, regionOwnerID: owner.id,
            tempoBPM: 60, tempoTimebase: .relative, tempoReferenceBPM: 120))
    }
    project.songs = [song]
    let markers = song.markers
    let printed = try ItemReRender.render(project: project, song: song, track: track, clip: clip, directory: root,
        settings: encoding, cancellation: AudioExportCancellation())
    precondition(printed.id == clip.id && printed.regionOwnerID == owner.id)
    precondition(printed.startTime == clip.startTime && printed.duration == clip.duration)
    precondition(printed.sourceOffset == 0 && printed.audioRate == 1 && printed.renderedTempo == true)
    precondition(printed.renderedTiming != true && printed.tempoBasePlaybackRate == nil,
        "Printed tempo must leave region pitch live and clear the old rate reference")
    precondition(song.markers == markers && song.parts == [owner, foreign], "Printing must preserve region and marker positions")
    precondition(song.tempoAudioSegments(printed).count == 1 && song.tempoAudioSegments(printed)[0].audioRate == 1)
    precondition(TimelineItemPlaybackRate.title(printed.name, rates: song.tempoAudioSegments(printed).map(\.audioRate)) == printed.name)
    let pcm = try samples(root.appendingPathComponent(printed.audioFile!.path))
    precondition(pcm.count == Int(clip.duration * sampleRate), "Printed duration must match the stretched item")
    let initial = rms(pcm, 0.3), firstBand = rms(pcm, 1.2)
    precondition(abs(firstBand / initial - 4) < 0.18, "Rerender must bake the first 1.5x section into PCM")
    precondition(abs(initial - 0.025 * 0.8 / sqrt(2)) < 0.003, "Only item gain is baked; track fader remains live")
    let middle = rms(pcm, 2.45), last = rms(pcm, 3.4)
    precondition(abs(last / initial - 1.6) < 0.12, "Foreign song tempo must not affect the item's tail")
    if variable {
        precondition(abs(middle / initial - 4) < 0.18, "Second 0.5x section must delay the next amplitude boundary")
    } else {
        precondition(abs(middle / initial - 1.6) < 0.12, "Constant 1.5x section must reach the final band sooner")
    }
    var replaySong = song
    replaySong.tracks[0].clips = [printed]
    let again = try ItemReRender.render(project: project, song: replaySong, track: replaySong.tracks[0], clip: printed,
        directory: root, settings: encoding, cancellation: AudioExportCancellation())
    let repeated = try samples(root.appendingPathComponent(again.audioFile!.path))
    precondition(repeated.count == pcm.count)
    precondition(zip(pcm, repeated).map { abs($0 - $1) }.max()! < 0.00002,
        "A second render must preserve PCM without applying the tempo map twice")
    precondition(abs(frequency(pcm, 1.2) - 440) < 12, "Item printing must leave the region's octave shift live")
    let pitchedFolder = root.appendingPathComponent(variable ? "pitched-variable" : "pitched-constant")
    let pitchedJob = AudioExportJob(id: printed.id.uuidString, fileName: "pitched.wav", start: printed.startTime,
        end: printed.startTime + printed.duration, track: track.id, clip: printed.id)
    try OfflineAudioExport.run(project: project, song: replaySong, plan: AudioExportPlan(jobs: [pitchedJob]), mediaDirectory: root,
        outputDirectory: pitchedFolder, sampleRate: sampleRate, cancellation: AudioExportCancellation()) { _ in }
    let pitched = try samples(pitchedFolder.appendingPathComponent("pitched.wav"))
    precondition(abs(frequency(pitched, 1.2) - 880) < 12,
        "A rerendered item's region pitch must still reach subsequent playback/export")
    print(variable ? "RERENDER_VARIABLE_OWNED_TEMPO_PCM_AND_RESET_OK" : "RERENDER_CONSTANT_TEMPO_PCM_AND_RESET_OK")
}
