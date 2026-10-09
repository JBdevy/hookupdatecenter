import Foundation
import AVFoundation
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let format = AVAudioFormat(standardFormatWithSampleRate: 48000,channels: 2)!
func tone(_ name: String, _ amplitude: Float) throws {
    let buffer = AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 48000)!
    buffer.frameLength = 48000
    for c in 0..<2 { for f in 0..<48000 { buffer.floatChannelData![c][f] = amplitude * sin(Float(f)*0.13) } }
    let file = try AVAudioFile(forWriting: root.appendingPathComponent(name),settings: format.settings)
    try file.write(from: buffer)
}
try tone("a.wav",0.2); try tone("b.wav",0.3)
var project = Project.empty(name: "Export fixture")
var a = Track(id: UUID(),name: "Click",role: .click), b = Track(id: UUID(),name: "Bass",role: .bass)
a.clips = [AudioClip(id:UUID(),name:"a.wav",startTime:0.25,duration:1,audioFile:AudioFile(path:"a.wav"))]
b.clips = [AudioClip(id:UUID(),name:"b.wav",startTime:0.5,duration:0.5,audioFile:AudioFile(path:"b.wav"))]
project.songs[0].tracks = [a,b]
let song = project.songs[0]
let plan = AudioExportPlan(project:project,song:song,source:.masterAndTracks,bounds:.project,template:"%track for today",tracks:[a.id,b.id],clips:[],regions:[])
precondition(plan.jobs.map(\.fileName) == ["Master for today Master.wav","Click for today.wav","Bass for today.wav"])
let output = root.appendingPathComponent("output")
var reports: [AudioExportProgress] = []
try OfflineAudioExport.run(project: project,song: song,plan: plan,mediaDirectory: root,outputDirectory: output,sampleRate: 48000,cancellation: AudioExportCancellation()) { reports.append($0) }
func read(_ fileName: String) throws -> [Float] {
    let file = try AVAudioFile(forReading:output.appendingPathComponent(fileName))
    precondition(file.length == 60000,"complete-project duration is exact")
    let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length))!
    try file.read(into:buffer)
    return Array(UnsafeBufferPointer(start:buffer.floatChannelData![0],count:Int(buffer.frameLength)))
}
let master = try read(plan.jobs[0].fileName), left = try read(plan.jobs[1].fileName), right = try read(plan.jobs[2].fileName)
FileHandle.standardError.write(Data("PCM peaks \(master.map { abs($0) }.max()!) \(left.map { abs($0) }.max()!) \(right.map { abs($0) }.max()!) first \(left.firstIndex(where:{ abs($0)>0.001 }) ?? -1) \(right.firstIndex(where:{ abs($0)>0.001 }) ?? -1)\n".utf8))
precondition(left[0..<11000].allSatisfy { abs($0) < 0.000001 },"leading silence is retained")
precondition(left[14000..<22000].map { abs($0) }.max()! > 0.19,"later item starts at its timeline position")
precondition(right[0..<22000].allSatisfy { abs($0) < 0.000001 },"other track has its own onset")
precondition(right[27000..<45000].map { abs($0) }.max()! > 0.29,"every track renders")
for frame in stride(from:27000,to:45000,by:127) { precondition(abs(master[frame]-left[frame]-right[frame]) < 0.00002,"Master equals simultaneous track mix") }
precondition(reports.last?.completed == 3 && reports.last?.total == 3)
precondition(reports.last!.waveform.max()! > 0.29,"display uses real rendered samples")
// Free Grid and a marker's Free override preserve the rendered source across
// tempo boundaries for Master, tracks and individual selected stems.
func renderedPCM(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let data = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: data)
    return Array(UnsafeBufferPointer(start: data.floatChannelData![0], count: Int(data.frameLength)))
}
var tempoSong = song
tempoSong.markers = [TimelineMarker(id: UUID(), name: "TEMPO", position: 0.4, color: 0x999999, tempoBPM: 180),
                     TimelineMarker(id: UUID(), name: "TEMPO", position: 0.8, color: 0x999999, tempoBPM: 60)]
for timebase in [ProjectTimebase.free, .relative] {
    tempoSong.timeSettings = ProjectTimeSettings(); tempoSong.timeSettings?.timebase = timebase
    for i in tempoSong.markers!.indices { tempoSong.markers![i].tempoTimebase = timebase == .free ? .global : .free }
    let folder = root.appendingPathComponent("free-tempo-" + timebase.rawValue)
    try OfflineAudioExport.run(project: project, song: tempoSong, plan: plan, mediaDirectory: root, outputDirectory: folder, sampleRate: 48000, cancellation: AudioExportCancellation()) { _ in }
    for job in plan.jobs {
        let baseline = try renderedPCM(output.appendingPathComponent(job.fileName))
        let actual = try renderedPCM(folder.appendingPathComponent(job.fileName))
        precondition(baseline.count == actual.count && !baseline.isEmpty)
        precondition(zip(baseline, actual).map { abs($0 - $1) }.max()! < 0.00001, "Free Grid exports preserve PCM: \(job.fileName)")
    }
}
let tempoStemPlan = AudioExportPlan(project: project, song: song, source: .stems, bounds: .project, template: "%stem", tracks: [], clips: [a.clips[0].id, b.clips[0].id], regions: [])
let baselineStemsFolder = root.appendingPathComponent("baseline-tempo-stems"), tempoStemsFolder = root.appendingPathComponent("free-tempo-stems")
try OfflineAudioExport.run(project: project, song: song, plan: tempoStemPlan, mediaDirectory: root, outputDirectory: baselineStemsFolder, sampleRate: 48000, cancellation: AudioExportCancellation()) { _ in }
try OfflineAudioExport.run(project: project, song: tempoSong, plan: tempoStemPlan, mediaDirectory: root, outputDirectory: tempoStemsFolder, sampleRate: 48000, cancellation: AudioExportCancellation()) { _ in }
for job in tempoStemPlan.jobs {
    let baseline = try renderedPCM(baselineStemsFolder.appendingPathComponent(job.fileName))
    let actual = try renderedPCM(tempoStemsFolder.appendingPathComponent(job.fileName))
    precondition(baseline.count == actual.count && !baseline.isEmpty)
    precondition(zip(baseline, actual).map { abs($0 - $1) }.max()! < 0.00001, "Free marker also preserves selected stem PCM")
}
print("FREE_GRID_GLOBAL_AND_LOCAL_OVERRIDE_MASTER_TRACKS_AND_STEMS_EXPORT_PCM_OK")
// A shorter stem finishes first; the same display then follows the next file.
var short = b.clips[0]; short.startTime = 0; short.duration = 0.2; short.gain = 5
var long = a.clips[0]; long.startTime = 0; long.duration = 1
var stemsSong = song; stemsSong.tracks[0].clips = [short,long]
stemsSong.tracks[1].clips = []
let stemPlan = AudioExportPlan(project:project,song:stemsSong,source:.stems,bounds:.project,template:"%stem",tracks:[],clips:[short.id,long.id],regions:[])
var stemReports: [AudioExportProgress] = []
try OfflineAudioExport.run(project: project,song: stemsSong,plan: stemPlan,mediaDirectory: root,outputDirectory: root.appendingPathComponent("stems"),sampleRate: 44100,cancellation: AudioExportCancellation()) { stemReports.append($0) }
precondition(stemReports.contains { $0.fileName == "b.wav" && $0.peak > 1 && $0.clipped.contains(true) },"clipping is measured before integer WAV encoding")
precondition(stemReports.contains { $0.fileName == "a.wav" && $0.completed >= 1 },"display moves to the next unfinished output")
precondition(stemReports.last?.completed == 2)
// Missing media rolls back all outputs, including temporary WAVs.
var invalid = song; invalid.tracks[1].clips[0].audioFile = AudioFile(path:"missing.wav")
let failureFolder = root.appendingPathComponent("failure")
do {
    try OfflineAudioExport.run(project:project,song:invalid,plan:plan,mediaDirectory:root,outputDirectory:failureFolder,sampleRate:48000,cancellation:AudioExportCancellation()) { _ in }
    fatalError("missing media must fail")
} catch { let remaining = try FileManager.default.contentsOfDirectory(atPath:failureFolder.path); precondition(remaining.isEmpty) }
// Both output encodings consume the same rendered PCM in the same pass.
let primary = AudioExportPlan(project:project,song:song,source:.masterAndTracks,bounds:.area,template:"%track",tracks:[a.id],clips:[],regions:[],area:0...0.7,format:.aiff)
let secondary = AudioExportPlan(project:project,song:song,source:.masterAndTracks,bounds:.area,template:"%track",tracks:[a.id],clips:[],regions:[],area:0...0.7,format:.mp3)
let dual = AudioExportPlan.combining(primary:primary,secondary:secondary)
let dualFolder = root.appendingPathComponent("dual")
try OfflineAudioExport.run(project:project,song:song,plan:dual,mediaDirectory:root,outputDirectory:dualFolder,sampleRate:44100,
    encoding:AudioExportEncoding(format:.aiff,bitDepth:32,channels:1),secondaryEncoding:AudioExportEncoding(format:.mp3,channels:1,bitrate:128),cancellation:AudioExportCancellation()) { _ in }
for job in dual.jobs {
    let file = try AVAudioFile(forReading:dualFolder.appendingPathComponent(job.fileName))
    precondition(file.processingFormat.channelCount == 1 && file.processingFormat.sampleRate == 44100)
    if job.output == 0 { precondition(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 32 && file.fileFormat.settings[AVLinearPCMIsFloatKey] as? Bool == false) }
    else { precondition(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEGLayer3) }
}
let monoWavePlan = AudioExportPlan(project:project,song:song,source:.tracks,bounds:.area,template:"%track",tracks:[a.id],clips:[],regions:[],area:0...0.7)
let monoFolder = root.appendingPathComponent("mono32")
try OfflineAudioExport.run(project:project,song:song,plan:monoWavePlan,mediaDirectory:root,outputDirectory:monoFolder,sampleRate:48000,encoding:AudioExportEncoding(bitDepth:32,channels:1),cancellation:AudioExportCancellation()) { _ in }
let mono = try AVAudioFile(forReading:monoFolder.appendingPathComponent(monoWavePlan.jobs[0].fileName))
precondition(mono.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 32)
// 16-bit PCM is an actual output encoding for WAV and AIFF, not only a UI label.
for format: AudioExportFormat in [.wav, .aiff] {
    let pcm16Plan = AudioExportPlan(project: project, song: song, source: .tracks, bounds: .area,
        template: "%track", tracks: [a.id], clips: [], regions: [], area: 0...0.7, format: format)
    let folder = root.appendingPathComponent("pcm16-" + format.rawValue)
    try OfflineAudioExport.run(project: project, song: song, plan: pcm16Plan, mediaDirectory: root,
        outputDirectory: folder, sampleRate: 44100, encoding: AudioExportEncoding(format: format, bitDepth: 16),
        cancellation: AudioExportCancellation()) { _ in }
    let file = try AVAudioFile(forReading: folder.appendingPathComponent(pcm16Plan.jobs[0].fileName))
    precondition(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
    precondition(file.fileFormat.settings[AVLinearPCMIsFloatKey] as? Bool == false)
    precondition(file.length == 30870 && file.processingFormat.channelCount == 2)
    let defaults = UserDefaults(suiteName: "jaras.test.pcm16." + UUID().uuidString)!
    defaults.set(format.rawValue, forKey: "jaras.media.record.format")
    defaults.set(16, forKey: "jaras.media.record.bits")
    let recording = MediaProcessingFormat.load("record", preferences: defaults)
    precondition(recording.bitDepth == 16 && recording.recordingKey == format.fileExtension + "16pcm")
}
print("WAV_AIFF_16BIT_PCM_AND_RECORDING_PREFERENCE_OK")
// Folder routing, item/track effects and Master volume use the live chain order.
var groupSong = song
var folder = Track(id:UUID(),name:"Group",role:.other); folder.volume = 0.25
var child = a; child.parentTrackID = folder.id; child.volume = 0.5
child.clips[0].gain = 0.5
var comp = NativeFXSettings(); comp.compressorEnabled = true; comp.ratio = 1; comp.threshold = 0; comp.makeup = 6
child.clips[0].fx = comp; child.fx = comp
groupSong.tracks = [folder,child]
var groupProject = project; groupProject.masterVolume = 0.5; groupProject.songs[0] = groupSong
let groupedPlan = AudioExportPlan(project:groupProject,song:groupSong,source:.masterAndTracks,bounds:.project,template:"%track",tracks:[folder.id,child.id],clips:[],regions:[])
let groupFolder = root.appendingPathComponent("group")
try OfflineAudioExport.run(project:groupProject,song:groupSong,plan:groupedPlan,mediaDirectory:root,outputDirectory:groupFolder,sampleRate:48000,cancellation:AudioExportCancellation()) { _ in }
func outputPeak(_ url: URL) throws -> Float {
    let file = try AVAudioFile(forReading:url)
    let data = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length))!
    try file.read(into:data)
    return UnsafeBufferPointer(start:data.floatChannelData![0],count:Int(data.frameLength)).map { abs($0) }.max()!
}
// Drawer song renders use the same onset exclusion as live playback. Include an
// ordinary region with identical bounds to catch incorrectly shared graphs.
var drawerSong = song
let unified = Part(id: UUID(), name: "Unified", startTime: 0.25, endTime: 1.25)
let drawer = Part(id: UUID(), name: "Drawer song", startTime: 0.5, endTime: 1, parentRegionID: unified.id)
let ordinary = Part(id: UUID(), name: "Ordinary", startTime: 0.5, endTime: 1)
drawerSong.parts = [unified, drawer, ordinary]
for source in [AudioExportSource.master, .tracks, .masterAndTracks] {
    let selected = AudioExportPlan(project: project, song: drawerSong, source: source, bounds: .regions, template: "%region %track", tracks: [a.id, b.id], clips: [], regions: [drawer.id, ordinary.id])
    let folder = root.appendingPathComponent("drawer-" + source.rawValue)
    try OfflineAudioExport.run(project: project, song: drawerSong, plan: selected, mediaDirectory: root, outputDirectory: folder, sampleRate: 48000, cancellation: AudioExportCancellation()) { _ in }
    for job in selected.jobs {
        let file = try AVAudioFile(forReading: folder.appendingPathComponent(job.fileName))
        precondition(file.length == 24000, "drawer duration is exact")
        let peak = try outputPeak(folder.appendingPathComponent(job.fileName))
        let fullMixPeak = master[24000..<48000].map { abs($0) }.max()!
        let expected: Float = job.track == a.id ? (job.minimumClipStart == nil ? 0.2 : 0) : job.track == b.id ? 0.3 : job.minimumClipStart == nil ? fullMixPeak : 0.3
        precondition(abs(peak - expected) < 0.001, "previous song stems must be excluded only from drawer renders: \(job.fileName), \(peak) vs \(expected)")
    }
}
print("DRAWER_MASTER_TRACKS_AND_MASTER_PLUS_TRACKS_EXCLUDE_PREVIOUS_STEMS_OK")
// Receive and Transmitter names are opposite views of one connection.
var routeSong = song
var sender = a; sender.patch = OutputPatch.none
var receiver = Track(id: UUID(), name: "Receiver", role: .other); receiver.volume = 0.25
sender.routing = TrackRouting(transmitters: [receiver.id, nil]); receiver.routing = TrackRouting(receives: [sender.id, nil])
routeSong.tracks = [sender, receiver]
let routePlan = AudioExportPlan(project: project, song: routeSong, source: .masterAndTracks, bounds: .project, template: "%track", tracks: [sender.id, receiver.id], clips: [], regions: [])
let routeFolder = root.appendingPathComponent("direct-routes")
try OfflineAudioExport.run(project: project, song: routeSong, plan: routePlan, mediaDirectory: root, outputDirectory: routeFolder, sampleRate: 48000, cancellation: AudioExportCancellation()) { _ in }
let sent = try outputPeak(routeFolder.appendingPathComponent(routePlan.jobs[1].fileName))
let received = try outputPeak(routeFolder.appendingPathComponent(routePlan.jobs[2].fileName))
let routedMaster = try outputPeak(routeFolder.appendingPathComponent(routePlan.jobs[0].fileName))
precondition(abs(sent - 0.2) < 0.001 && abs(received - 0.05) < 0.001 && abs(routedMaster - 0.05) < 0.001, "the duplicate Receive/Transmitter pair must not double the PCM")
print("OFFLINE_RECEIVE_TRANSMITTER_DEDUPLICATED_STEREO_ROUTING_PCM_OK")
let childPeak = try outputPeak(groupFolder.appendingPathComponent(groupedPlan.jobs[2].fileName))
let folderPeak = try outputPeak(groupFolder.appendingPathComponent(groupedPlan.jobs[1].fileName))
let masterPeak = try outputPeak(groupFolder.appendingPathComponent(groupedPlan.jobs[0].fileName))
precondition(abs(childPeak - 0.2 * 0.5 * 0.5 * pow(10,12/20)) < 0.005)
precondition(abs(folderPeak - childPeak*0.25) < 0.001 && abs(masterPeak-folderPeak*0.5) < 0.001)
// Loop seams continue beyond the scheduling horizon without dropping audio.
var repeatSong = song; repeatSong.tracks = [a]
repeatSong.tracks[0].clips[0].startTime = 0
repeatSong.tracks[0].clips[0].duration = 4
repeatSong.tracks[0].clips[0].loopStart = 0.1; repeatSong.tracks[0].clips[0].loopLength = 0.2
let loopPlan = AudioExportPlan(project:project,song:repeatSong,source:.tracks,bounds:.project,template:"Loop",tracks:[a.id],clips:[],regions:[])
let loopFolder = root.appendingPathComponent("loop")
try OfflineAudioExport.run(project:project,song:repeatSong,plan:loopPlan,mediaDirectory:root,outputDirectory:loopFolder,sampleRate:48000,cancellation:AudioExportCancellation()) { _ in }
let loopFile = try AVAudioFile(forReading:loopFolder.appendingPathComponent(loopPlan.jobs[0].fileName))
loopFile.framePosition = 3*48000
let loopBuffer = AVAudioPCMBuffer(pcmFormat:loopFile.processingFormat,frameCapacity:4096)!
try loopFile.read(into:loopBuffer)
precondition(UnsafeBufferPointer(start:loopBuffer.floatChannelData![0],count:Int(loopBuffer.frameLength)).map { abs($0) }.max()! > 0.19)
let cancelled = AudioExportCancellation(); cancelled.cancel()
let cancelFolder = root.appendingPathComponent("cancel")
do { try OfflineAudioExport.run(project:project,song:song,plan:plan,mediaDirectory:root,outputDirectory:cancelFolder,sampleRate:48000,cancellation:cancelled) { _ in }; fatalError("cancel must stop export") }
catch is CancellationError { let remaining = try FileManager.default.contentsOfDirectory(atPath:cancelFolder.path); precondition(remaining.isEmpty) }
// Large WAV output uses RF64 without allocating or writing the full duration.
let huge = AudioExportPlan(jobs:[AudioExportJob(id:"huge",fileName:"large.wav",start:0,end:50000,track:a.id,clip:nil)])
let hugeFolder = root.appendingPathComponent("rf64"), hugeCancel = AudioExportCancellation()
var sawRF64 = false
do {
    try OfflineAudioExport.run(project:project,song:song,plan:huge,mediaDirectory:root,outputDirectory:hugeFolder,sampleRate:48000,cancellation:hugeCancel) { _ in
        if let file = try? FileManager.default.contentsOfDirectory(at:hugeFolder,includingPropertiesForKeys:nil).first {
            let handle = try? FileHandle(forReadingFrom:file)
            let header = try? handle?.read(upToCount:64)
            let bytes = header ?? Data()
            sawRF64 = bytes.prefix(4) == Data("RF64".utf8) || (bytes.prefix(4) == Data("RIFF".utf8) && bytes.range(of: Data("JUNK".utf8)) != nil)
            try? handle?.close()
        }
        hugeCancel.cancel()
    }
    fatalError("cancel must stop a large export")
} catch is CancellationError { precondition(sawRF64,"large WAV reserves the RF64 size header before the 4 GB boundary"); let files = try FileManager.default.contentsOfDirectory(atPath:hugeFolder.path); precondition(files.isEmpty) }
// Every track advances together, including a dense 400-track session.
var dense = song
let shared = a.clips[0]
dense.tracks = (0..<400).map { index in
    var track = Track(id:UUID(),name:"Track \(index)",role:.other)
    var clip = shared; clip.id = UUID(); clip.startTime = 0; clip.duration = 0.03
    track.clips = [clip]; return track
}
let densePlan = AudioExportPlan(project:project,song:dense,source:.masterAndTracks,bounds:.project,template:"%track",tracks:Set(dense.tracks.map(\.id)),clips:[],regions:[])
var denseLast: AudioExportProgress?
try OfflineAudioExport.run(project:project,song:dense,plan:densePlan,mediaDirectory:root,outputDirectory:root.appendingPathComponent("dense"),sampleRate:48000,cancellation:AudioExportCancellation()) { denseLast = $0 }
precondition(denseLast?.completed == 401 && denseLast!.waveform.max()! > 0.19)
print("OFFLINE_SIMULTANEOUS_400_TRACKS_MASTER_STEMS_DUAL_FORMATS_MONO_STEREO_TIMING_CLIPPING_AND_ROLLBACK_OK")

// Saved per-song pitch and native Pitch use the same settings in exported PCM.
var pitchSong = song
pitchSong.parts = [Part(id: UUID(), name: "Pitch", startTime: 0, endTime: 1.25, pitchSemitones: 6, pitchTrackIDs: [a.id], pitchGroupIDs: [])]
var pitchFX = NativeFXSettings(); pitchFX.inserted = ["Pitch"]; pitchFX.pitchEnabled = true; pitchFX.pitchSemitones = -12
pitchSong.tracks[1].fx = pitchFX
var pitchProject = project; pitchProject.songs[0] = pitchSong
let pitchPlan = AudioExportPlan(project: pitchProject, song: pitchSong, source: .tracks, bounds: .project, template: "%track", tracks: [a.id,b.id], clips: [], regions: [])
let pitchFolder = root.appendingPathComponent("pitch")
try OfflineAudioExport.run(project: pitchProject, song: pitchSong, plan: pitchPlan, mediaDirectory: root, outputDirectory: pitchFolder, sampleRate: 48000, cancellation: AudioExportCancellation()) { _ in }
for (index, job) in pitchPlan.jobs.enumerated() {
    let file = try AVAudioFile(forReading: pitchFolder.appendingPathComponent(job.fileName))
    precondition(file.length == 60000, "pitch preserves export bounds")
    let data = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: data)
    let start = index == 0 ? 28800 : 31200, end = index == 0 ? 48000 : 40800
    var crossings = 0
    for i in (start+1)..<end { if data.floatChannelData![0][i-1] < 0 && data.floatChannelData![0][i] >= 0 { crossings += 1 } }
    let measured = Double(crossings) * 48000 / Double(end-start)
    let original = 0.13 * 48000 / (2 * Double.pi)
    let expected = original * (index == 0 ? pow(2,0.5) : 0.5)
    precondition(abs(measured-expected) < 8, "export pitch frequency \(measured), expected \(expected)")
}
print("OFFLINE_REGION_AND_NATIVE_PITCH_PCM_AND_DURATION_OK")

func verifyFrozenItem() throws {
    var freeze = Project.empty(name: "Freeze")
    var channel = Track(id: UUID(), name: "Click", role: .click, volume: 0.1, pan: 0.5, mute: true, solo: false)
    let original = AudioClip(id: UUID(), name: "click.wav", startTime: 0.5, duration: 0.5, audioFile: AudioFile(path: "a.wav"), gain: 0.5, normalizationGain: 0.5, muted: true)
    channel.clips = [original]; freeze.songs[0].tracks = [channel]; freeze.songs[0].duration = 1
    let a = try ItemReRender.render(project: freeze, song: freeze.songs[0], track: channel, clip: original, directory: root,
                                  settings: MediaProcessingFormat(format: .wav, bitDepth: 24, bitrate: 320), cancellation: AudioExportCancellation())
    precondition(a.id == original.id && a.startTime == original.startTime && a.duration == original.duration)
    precondition(a.muted == true && a.gain == 1 && a.normalizationGain == nil && a.fx == nil && a.audioRate == 1 && a.sourceOffset == 0)
    precondition(a.audioFile?.path == "Stems/click-001.wav")
    let audio = try AVAudioFile(forReading: root.appendingPathComponent(a.audioFile!.path))
    let pcm = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
    try audio.read(into: pcm)
    let maximum = (0..<Int(pcm.frameLength)).map { abs(pcm.floatChannelData![0][$0]) }.max()!
    precondition(abs(maximum - 0.05) < 0.003, "freeze bakes normalization and item gain once while leaving track volume, pan and mute live")
    let b = try ItemReRender.render(project: freeze, song: freeze.songs[0], track: channel, clip: original, directory: root,
                                  settings: MediaProcessingFormat(format: .aiff, bitDepth: 32, bitrate: 320), cancellation: AudioExportCancellation())
    precondition(b.audioFile?.path == "Stems/click-001.aiff")
    let c = try ItemReRender.render(project: freeze, song: freeze.songs[0], track: channel, clip: a, directory: root,
                                  settings: MediaProcessingFormat(format: .wav, bitDepth: 24, bitrate: 320), cancellation: AudioExportCancellation())
    precondition(c.audioFile?.path == "Stems/click-002.wav")
    precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent(original.audioFile!.path).path))
    precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent(a.audioFile!.path).path), "all previous sources remain available for Undo")
    print("FREEZE_ITEM_GAIN_ONCE_SOURCE_PRESERVATION_EXACT_POSITION_AND_SEQUENTIAL_SUFFIX_OK")
}
try verifyFrozenItem()

// Item envelopes span the complete repeated item, never restart at a source
// wrap, and are baked exactly once by Re-render.
do {
    var fadedProject = Project.empty(name: "Fades")
    var fadeTrack = Track(id: UUID(), name: "Fade", role: .other)
    var clip = AudioClip(id: UUID(), name: "Repeated", startTime: 0.5, duration: 3, audioFile: AudioFile(path: "a.wav"), loopStart: 0, loopLength: 1)
    fadeTrack.clips = [clip]; fadedProject.songs[0].tracks = [fadeTrack]
    func exportFade(_ name: String) throws -> [Float] {
        let song = fadedProject.songs[0]
        let plan = AudioExportPlan(project: fadedProject, song: song, source: .stems, bounds: .project, template: name,
                                   tracks: [fadeTrack.id], clips: [clip.id], regions: [])
        try OfflineAudioExport.run(project: fadedProject, song: song, plan: plan, mediaDirectory: root, outputDirectory: output,
                                   sampleRate: 48000, cancellation: AudioExportCancellation(), progress: { _ in })
        return try renderedPCM(output.appendingPathComponent(plan.jobs[0].fileName))
    }
    let dry = try exportFade("fade-dry")
    clip.fadeIn = 2.5; clip.fadeOut = 1.5
    fadedProject.songs[0].tracks[0].clips = [clip]
    let faded = try exportFade("fade-shaped")
    precondition(dry.count == faded.count)
    var error = 0.0
    for i in 0..<dry.count {
        let t = Double(i) / 48000
        func curve(_ input: Double) -> Double { let x = min(1, max(0, input)); return x*x*(3-2*x) }
        error = max(error, abs(Double(faded[i]) - Double(dry[i]) * curve(t/2.5) * curve((3-t)/1.5)))
    }
    precondition(error < 0.0002, "rendered fades match the whole-item envelope across source repeats: \(error)")
    let frozen = try ItemReRender.render(project: fadedProject, song: fadedProject.songs[0], track: fadedProject.songs[0].tracks[0], clip: clip,
                                         directory: root, settings: MediaProcessingFormat(format: .wav, bitDepth: 24, bitrate: 320), cancellation: AudioExportCancellation(), progress: { _ in })
    precondition(frozen.fadeIn == nil && frozen.fadeOut == nil, "Re-render removes baked envelopes so they cannot be applied twice")
    print("OFFLINE_ITEM_FADES_REPEAT_OVERLAP_AND_FREEZE_ONCE_OK")
}

// Original channels are resolved independently, including a track-level source
// fallback, so one mixed selection never adopts its first item's channel count.
do {
    let monoFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let monoPCM = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 48000)!
    monoPCM.frameLength = 48000
    for frame in 0..<48000 { monoPCM.floatChannelData![0][frame] = 0.2 * sin(Float(frame) * 0.13) }
    do {
        let file = try AVAudioFile(forWriting: root.appendingPathComponent("original-mono.wav"), settings: monoFormat.settings)
        try file.write(from: monoPCM)
    }
    var mixedProject = Project.empty(name: "Original channels")
    var monoTrack = Track(id: UUID(), name: "Mono", role: .click)
    monoTrack.audioFile = AudioFile(path: "original-mono.wav")
    monoTrack.clips = [AudioClip(id: UUID(), name: "Mono", startTime: 0, duration: 0.3)]
    var stereoTrack = Track(id: UUID(), name: "Stereo", role: .bass)
    stereoTrack.clips = [AudioClip(id: UUID(), name: "Stereo", startTime: 0.1, duration: 0.3, audioFile: AudioFile(path: "a.wav"))]
    mixedProject.songs[0].tracks = [monoTrack, stereoTrack]
    let mixedSong = mixedProject.songs[0]
    for outputFormat in AudioExportFormat.allCases {
        let mixedPlan = AudioExportPlan(project: mixedProject, song: mixedSong, source: .stems, bounds: .project,
                                       template: "%stem", tracks: [], clips: Set(mixedSong.tracks.flatMap(\.clips).map(\.id)), regions: [], format: outputFormat)
        for channels in [0, 1, 2] {
            let folder = root.appendingPathComponent("channels-\(outputFormat.rawValue)-\(channels)")
            try OfflineAudioExport.run(project: mixedProject, song: mixedSong, plan: mixedPlan, mediaDirectory: root,
                                       outputDirectory: folder, sampleRate: 48000,
                                       encoding: AudioExportEncoding(format: outputFormat, channels: channels), cancellation: AudioExportCancellation()) { _ in }
            for job in mixedPlan.jobs {
                let file = try AVAudioFile(forReading: folder.appendingPathComponent(job.fileName))
                let expected = channels == 0 ? (job.track == monoTrack.id ? 1 : 2) : channels
                precondition(file.processingFormat.channelCount == expected,
                             "Original preserves each mono/stereo item, while explicit overrides still apply: \(job.fileName)")
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: buffer)
                let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
                precondition(samples.contains { abs($0) > 0.05 }, "resolving channels cannot silence the export")
            }
        }
    }
    print("OFFLINE_ORIGINAL_MIXED_MONO_STEREO_WAV_AIFF_MP3_AND_OVERRIDES_OK")
}

// Licensing is independent of user-controlled master/track gains.
@MainActor func verifyLicenseOutputGate() throws {
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let renderer = StemAudioPlayback(engine: engine, realtime: false)
    renderer.setLicenseAllowed(false)
    renderer.open(directory: root)
    var fixture = project
    fixture.songs[0].tracks[0].clips[0].startTime = 0
    var snapshot = ShowSnapshot(project: fixture, transport: TransportState(playing: true, songId: fixture.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    snapshot.transport.songId = fixture.songs[0].id
    snapshot.transport.playing = true
    try renderer.update(snapshot, revision: 1)
    renderer.previewVolume(nil, gain: 2)
    renderer.previewVolume(a.id, gain: 2)
    func peak() throws -> Float {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        var value: Float = 0
        for n in 0..<20 {
            let status = try engine.renderOffline(512, to: buffer)
            precondition(status == .success)
            if n > 10 { for c in 0..<2 { for f in 0..<Int(buffer.frameLength) { value = max(value, abs(buffer.floatChannelData![c][f])) } } }
        }
        return value
    }
    let silent = try peak()
    precondition(silent == 0, "license block survives project open and user fader changes")
    renderer.setLicenseAllowed(true)
    let audible = try peak()
    precondition(audible > 0.1, "valid authorization restores the existing graph")
    renderer.setLicenseAllowed(false)
    let silentAgain = try peak()
    precondition(silentAgain == 0, "revocation silences an already running graph")
    renderer.prepareForClosing()
    print("LICENSE_FINAL_OUTPUT_PCM_SILENCE_AND_REAUTH_OK")
}
try MainActor.assumeIsolated { try verifyLicenseOutputGate() }
AudioLicenseAccess.shared.setAllowed(false)
do {
    try OfflineAudioExport.run(project: project, song: song, plan: plan, mediaDirectory: root,
        outputDirectory: root.appendingPathComponent("license-blocked"), sampleRate: 48000,
        cancellation: AudioExportCancellation(), progress: { _ in })
    preconditionFailure("expired access must not export audio")
} catch BackendFailure.expired {}
AudioLicenseAccess.shared.setAllowed(true)
print("LICENSE_OFFLINE_EXPORT_BLOCK_OK")

do {
    var fixture = Project.empty(name: "MIDI freeze fixture")
    let midi = MIDIItem(notes: [MIDINote(start: 0.6, length: 1, pitch: 60, velocity: 110)], sourceBPM: 120)
    let original = AudioClip(id: UUID(), name: "Performed MIDI", startTime: 2, duration: 0.5,
                             sourceOffset: 0.05, muted: true, playbackRate: 1.5, midi: midi)
    var track = Track(id: UUID(), name: "Instrument", role: .keys)
    track.clips = [original]
    fixture.songs[0].tracks = [track]
    for channels in [1, 2] {
        let result = try ItemReRender.renderMIDI(project: fixture, song: fixture.songs[0], track: track, clip: original,
            directory: root, channels: channels, instruments: [:], cancellation: AudioExportCancellation())
        precondition(result.id == original.id && result.startTime == original.startTime && result.duration == original.duration)
        precondition(result.midi == nil && result.frozenMIDI == true && original.midi == midi && result.muted == true)
        precondition(result.audioFile?.path.hasPrefix("Stems/") == true && result.sourceOffset == 0 && result.audioRate == 1)
        let file = try AVAudioFile(forReading: root.appendingPathComponent(result.audioFile!.path))
        precondition(Int(file.processingFormat.channelCount) == channels && file.length == 24000)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 24000)!
        try file.read(into: buffer)
        for channel in 0..<channels { precondition((0..<24000).allSatisfy { buffer.floatChannelData![channel][$0] == 0 }) }
        precondition(!result.waveform.isEmpty && result.waveform.allSatisfy { $0 == 0 })
    }
    var fx = NativeFXSettings()
    var parameters = InstrumentParameters()
    parameters.attack = 0.001; parameters.hold = 0; parameters.decay = 0.001; parameters.sustain = 1; parameters.release = 0.01
    let key = fx.appendNative("Instruments", instrument: "fixture", parameters: parameters)
    track.fx = fx; track.volume = 0; track.mute = true
    fixture.songs[0].tracks = [track]
    let before = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Stems").path).sorted()
    do {
        _ = try ItemReRender.renderMIDI(project: fixture, song: fixture.songs[0], track: track, clip: original,
            directory: root, channels: 2, instruments: [:], cancellation: AudioExportCancellation())
        preconditionFailure("An inserted but unavailable instrument must not silently replace MIDI")
    } catch {}
    let after = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Stems").path).sorted()
    precondition(after == before)
    if let source = ProcessInfo.processInfo.environment["JARAS_TEST_SF2"] {
        let instruments = [key: OfflineMIDIInstrument(url: URL(fileURLWithPath: source), parameters: parameters, drums: false, monophonic: false)]
        for channels in [1, 2] {
            let result = try ItemReRender.renderMIDI(project: fixture, song: fixture.songs[0], track: track, clip: original,
                directory: root, channels: channels, instruments: instruments, cancellation: AudioExportCancellation())
            let file = try AVAudioFile(forReading: root.appendingPathComponent(result.audioFile!.path))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let samples = Array(UnsafeBufferPointer<Float>(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            precondition(Int(file.processingFormat.channelCount) == channels && file.length == 24000)
            precondition(samples.allSatisfy(\.isFinite))
            precondition(samples.prefix(4800).allSatisfy { abs($0) < 0.000001 }, "MIDI trim/rate must preserve the silence before the note")
            precondition(samples.dropFirst(10000).contains { abs($0) > 0.0001 }, "The inserted instrument must render audible MIDI even with live track mute/fader at zero")
            precondition(result.midi == nil && original.midi == midi && result.waveform.contains { $0 > 0 })
        }
        print("MIDI_FREEZE_SF2_AUDIBLE_MONO_STEREO_TRIM_RATE_AND_LIVE_TRACK_GAIN_NOT_BAKED_OK")
        var tempoFixture = fixture
        tempoFixture.songs[0].timeSettings = ProjectTimeSettings()
        tempoFixture.songs[0].timeSettings?.timebase = .relative
        tempoFixture.songs[0].markers = [TimelineMarker(id: UUID(), name: "TEMPO", position: 2, color: 0,
                                                       tempoBPM: 240, tempoTimebase: .relative, tempoReferenceBPM: 120)]
        let tempoSource = tempoFixture.songs[0]
        var active = original; active.muted = false
        let frozen = try ItemReRender.renderMIDI(project: tempoFixture, song: tempoSource, track: track, clip: active,
            directory: root, channels: 2, instruments: instruments, cancellation: AudioExportCancellation())
        let frozenPCM = try renderedPCM(root.appendingPathComponent(frozen.audioFile!.path))
        precondition(frozenPCM.prefix(3000).allSatisfy { abs($0) < 0.000001 })
        precondition(frozenPCM[5000..<7000].contains { abs($0) > 0.0001 }, "relative tempo must be printed once into MIDI PCM")
        tempoFixture.songs[0].tracks[0].clips = [frozen]
        tempoFixture.songs[0].tracks[0].volume = 1; tempoFixture.songs[0].tracks[0].mute = false
        let reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(tempoFixture))
        let reopenedSong = reopened.songs[0]
        precondition(reopenedSong.tempoAudioSegments(reopenedSong.tracks[0].clips[0]) == [frozen])
        let replay = root.appendingPathComponent("midi-tempo-reopened")
        let replayJob = AudioExportJob(id: "reopened", fileName: "reopened.wav", start: frozen.startTime,
                                      end: frozen.startTime + frozen.duration, track: track.id, clip: frozen.id)
        try OfflineAudioExport.run(project: reopened, song: reopenedSong, plan: AudioExportPlan(jobs: [replayJob]), mediaDirectory: root,
                                   outputDirectory: replay, sampleRate: 48000, cancellation: AudioExportCancellation(), progress: { _ in })
        let replayPCM = try renderedPCM(replay.appendingPathComponent("reopened.wav"))
        precondition(frozenPCM.count == replayPCM.count)
        precondition(zip(frozenPCM, replayPCM).allSatisfy { abs($0 - $1) < 0.00001 }, "reopened frozen WAV must not receive the relative tempo a second time")
        print("MIDI_FREEZE_RELATIVE_TEMPO_SF2_AND_REOPENED_AUDIO_PCM_NO_DOUBLE_TEMPO_OK")

        // Instrument nodes inject MIDI at their position in the ordered chain.
        // An EQ before the instrument must not start processing it after freeze,
        // while an EQ after the instrument must be printed exactly once.
        var orderedPCM: [[Float]] = []
        for instrumentFirst in [false, true] {
            var orderedFX = fx
            orderedFX.eqEnabled = true
            orderedFX.bands = [EQBand(frequency: 200, type: "highCut")]
            orderedFX.inserted = instrumentFirst ? [key, "EQ"] : ["EQ", key]
            var orderedTrack = track
            orderedTrack.fx = orderedFX; orderedTrack.volume = 1; orderedTrack.mute = false
            var orderedSource = active
            orderedSource.startTime = 0; orderedSource.sourceOffset = 0; orderedSource.playbackRate = 1
            orderedSource.duration = 0.6
            orderedSource.midi = MIDIItem(notes: [MIDINote(start: 0.2, length: 0.6, pitch: 60, velocity: 110)], sourceBPM: 120)
            orderedTrack.clips = [orderedSource]
            var orderedProject = fixture
            orderedProject.songs[0].tracks = [orderedTrack]
            let order = instrumentFirst ? "instrument-eq" : "eq-instrument"
            let directJob = AudioExportJob(id: "source", fileName: "source.wav", start: 0, end: 0.6, track: track.id, clip: orderedSource.id)
            let directDirectory = root.appendingPathComponent(order)
            try OfflineAudioExport.run(project: orderedProject, song: orderedProject.songs[0], plan: AudioExportPlan(jobs: [directJob]),
                mediaDirectory: root, outputDirectory: directDirectory, sampleRate: 48000, cancellation: AudioExportCancellation(),
                midiInstruments: instruments, progress: { _ in })
            let beforePCM = try renderedPCM(directDirectory.appendingPathComponent("source.wav"))
            let printed = try ItemReRender.renderMIDI(project: orderedProject, song: orderedProject.songs[0], track: orderedTrack,
                clip: orderedSource, directory: root, channels: 2, instruments: instruments, cancellation: AudioExportCancellation())
            let printedPCM = try renderedPCM(root.appendingPathComponent(printed.audioFile!.path))
            precondition(zip(beforePCM, printedPCM).allSatisfy { abs($0 - $1) < 0.00001 }, "freeze must preserve the full ordered FX chain")
            orderedPCM.append(printedPCM)
            orderedProject.songs[0].tracks[0].clips = [printed]
            let reloaded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(orderedProject))
            let replayDirectory = root.appendingPathComponent(order + "-reopened")
            try OfflineAudioExport.run(project: reloaded, song: reloaded.songs[0], plan: AudioExportPlan(jobs: [directJob]),
                mediaDirectory: root, outputDirectory: replayDirectory, sampleRate: 48000, cancellation: AudioExportCancellation(), progress: { _ in })
            let afterPCM = try renderedPCM(replayDirectory.appendingPathComponent("source.wav"))
            precondition(zip(beforePCM, afterPCM).allSatisfy { abs($0 - $1) < 0.00001 }, "reopened frozen audio must bypass already printed track FX")

            // Item processing and the track fader stay live after the conversion.
            orderedProject.songs[0].tracks[0].clips[0].gain = 0.5
            orderedProject.songs[0].tracks[0].clips[0].normalizationGain = 0.5
            orderedProject.songs[0].tracks[0].volume = 0.5
            let editedDirectory = root.appendingPathComponent(order + "-editable-gain")
            try OfflineAudioExport.run(project: orderedProject, song: orderedProject.songs[0], plan: AudioExportPlan(jobs: [directJob]),
                mediaDirectory: root, outputDirectory: editedDirectory, sampleRate: 48000, cancellation: AudioExportCancellation(), progress: { _ in })
            let editedPCM = try renderedPCM(editedDirectory.appendingPathComponent("source.wav"))
            precondition(zip(beforePCM, editedPCM).allSatisfy { abs($0 * 0.125 - $1) < 0.00002 }, "frozen item gain, normalization and track fader remain editable")

            if instrumentFirst {
                try MainActor.assumeIsolated {
                    let engine = AVAudioEngine()
                    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
                    let renderer = StemAudioPlayback(engine: engine, realtime: false)
                    renderer.instrumentFile = { _ in (URL(fileURLWithPath: source), false) }
                    renderer.open(directory: root)
                    var remaining = orderedSource
                    remaining.id = UUID(); remaining.startTime = 0.8
                    var live = reloaded
                    live.songs[0].tracks[0].clips = [printed, remaining]
                    live.songs[0].duration = 1.4
                    var snapshot = ShowSnapshot(project: live, transport: TransportState(playing: false, songId: live.songs[0].id,
                        position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
                    try renderer.update(snapshot, revision: 1)
                    let deadline = Date().addingTimeInterval(10)
                    while !renderer.isInstrumentReady(track.id), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
                    precondition(renderer.isInstrumentReady(track.id))
                    snapshot.transport.playing = true
                    try renderer.update(snapshot, revision: 1)
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
                    var frozenPeak: Float = 0, remainingPeak: Float = 0
                    for _ in 0..<263 {
                        let time = Double(engine.manualRenderingSampleTime) / format.sampleRate
                        snapshot.transport.position = time
                        try renderer.update(snapshot, revision: 1)
                        let status = try engine.renderOffline(256, to: buffer)
                        precondition(status == .success)
                        for frame in 0..<Int(buffer.frameLength) {
                            let value = abs(buffer.floatChannelData![0][frame])
                            if time > 0.15 && time < 0.35 { frozenPeak = max(frozenPeak, value) }
                            if time > 0.95 && time < 1.15 { remainingPeak = max(remainingPeak, value) }
                        }
                    }
                    precondition(frozenPeak > 0.0001 && remainingPeak > 0.0001, "converted audio and remaining live MIDI must both sound on the same track")
                    let expected = printedPCM.map { abs($0) }.max()!
                    precondition(abs(frozenPeak - expected) / expected < 0.1, "live playback must not apply the printed EQ twice")
                    renderer.prepareForClosing()
                }
            }
        }
        precondition(zip(orderedPCM[0], orderedPCM[1]).contains { abs($0 - $1) > 0.001 }, "fixture must distinguish EQ before and after the instrument")
        print("MIDI_FREEZE_FX_ORDER_PCM_REOPEN_LIVE_GAIN_AND_REMAINING_MIDI_OK")
    }
    print("MIDI_FREEZE_SILENT_MONO_STEREO_EXACT_DURATION_SOURCE_ID_POSITION_AND_MISSING_INSTRUMENT_ROLLBACK_OK")
}

do {
    var fixture = Project.empty(name: "Audio glue fixture")
    var fx = NativeFXSettings(); fx.eqEnabled = true; fx.inserted = ["EQ"]
    fx.bands = [EQBand(frequency: 400, type: "highCut")]
    var itemFX = NativeFXSettings(); itemFX.eqEnabled = true; itemFX.inserted = ["EQ"]
    itemFX.bands = [EQBand(frequency: 1600, type: "highCut")]
    let first = AudioClip(id: UUID(), name: "a.wav", startTime: 0.3, duration: 0.35, sourceOffset: 0.05,
        audioFile: AudioFile(path: "a.wav"), gain: 0.4, normalizationGain: 0.8, fadeIn: 0.05, fadeOut: 0.04, fx: itemFX)
    let overlapping = AudioClip(id: UUID(), name: "b.wav", startTime: 0.5, duration: 0.3, sourceOffset: 0.1,
        audioFile: AudioFile(path: "b.wav"), gain: 0.6, fadeOut: 0.03)
    let later = AudioClip(id: UUID(), name: "a.wav", startTime: 1.1, duration: 0.2, audioFile: AudioFile(path: "a.wav"), gain: 0.2)
    let clips = [first, overlapping, later]
    var track = Track(id: UUID(), name: "Glue", role: .keys)
    track.clips = clips; track.fx = fx; track.volume = 0.7
    fixture.songs[0].tracks = [track]
    fixture.songs[0].timeSettings = ProjectTimeSettings(); fixture.songs[0].timeSettings?.timebase = .relative
    fixture.songs[0].markers = [TimelineMarker(id: UUID(), name: "TEMPO", position: 0.6, color: 0,
        tempoBPM: 180, tempoTimebase: .relative, tempoReferenceBPM: 120)]
    let sourceSong = fixture.songs[0]
    let job = AudioExportJob(id: "glue", fileName: "glue.wav", start: 0.3, end: 1.3, track: track.id, clip: nil)
    let beforeDirectory = root.appendingPathComponent("glue-before")
    try OfflineAudioExport.run(project: fixture, song: sourceSong, plan: AudioExportPlan(jobs: [job]), mediaDirectory: root,
        outputDirectory: beforeDirectory, sampleRate: 48000, cancellation: AudioExportCancellation(), progress: { _ in })
    let before = try renderedPCM(beforeDirectory.appendingPathComponent("glue.wav"))
    let glued = try ItemReRender.glue(project: fixture, song: sourceSong, track: track, clips: clips,
        directory: root, cancellation: AudioExportCancellation())
    precondition(glued.startTime == 0.3 && abs(glued.duration - 1) < 0.000001 && glued.sourceOffset == 0 && glued.audioRate == 1)
    precondition(glued.fx == nil && glued.fadeIn == nil && glued.fadeOut == nil && glued.gain == 1 && glued.normalizationGain == nil)
    precondition(glued.renderedTiming == true && glued.frozenMIDI == nil && glued.midi == nil)
    let pcm = try renderedPCM(root.appendingPathComponent(glued.audioFile!.path))
    precondition(pcm.count == 48000 && pcm.allSatisfy(\.isFinite))
    // Stay away from the stretcher's short analysis window at either edge;
    // the middle of the gap must remain silent, including after tempo edits.
    precondition(pcm[27000..<33000].allSatisfy { abs($0) < 0.00001 }, "Glue must preserve silence between selected items")
    precondition(pcm[10000..<15000].contains { abs($0) > 0.02 }, "Overlapping items must contribute audible PCM")
    fixture.songs[0].tracks[0].clips = [glued]
    let reopened = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(fixture))
    let afterDirectory = root.appendingPathComponent("glue-reopened")
    try OfflineAudioExport.run(project: reopened, song: reopened.songs[0], plan: AudioExportPlan(jobs: [job]), mediaDirectory: root,
        outputDirectory: afterDirectory, sampleRate: 48000, cancellation: AudioExportCancellation(), progress: { _ in })
    let after = try renderedPCM(afterDirectory.appendingPathComponent("glue.wav"))
    precondition(before.count == after.count)
    precondition(zip(before, after).allSatisfy { abs($0 - $1) < 0.00003 }, "Glue/reopen preserves the audible sum, item FX and track FX without double tempo or FX")
    let single = try ItemReRender.glue(project: fixture, song: sourceSong, track: track, clips: [first], directory: root, cancellation: AudioExportCancellation())
    precondition(single.id != first.id && single.sourceOffset == 0 && abs(single.duration - first.duration) < 0.000000001)
    precondition(single.audioFile != first.audioFile && single.renderedTiming == true)
    var muted = first; muted.muted = true
    let mutedGlue = try ItemReRender.glue(project: fixture, song: sourceSong, track: track, clips: [muted], directory: root, cancellation: AudioExportCancellation())
    precondition(mutedGlue.muted == true && mutedGlue.waveform.contains { $0 > 0 }, "Single muted glue keeps the complete unmutable source")

    var midiTrack = Track(id: UUID(), name: "MIDI", role: .keys)
    let midi = AudioClip(id: UUID(), name: "MIDI", startTime: 0.3, duration: 1, midi: MIDIItem(notes: [MIDINote(start: 0.2, length: 1, pitch: 64)]))
    midiTrack.clips = [midi]
    var multiple = sourceSong; multiple.tracks = [track, midiTrack]
    let selection = Set(clips.map(\.id) + [midi.id])
    let baseline = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Stems").path).sorted()
    let cancellation = AudioExportCancellation()
    do {
        _ = try ItemReRender.glueSelection(project: fixture, song: multiple, ids: selection, directory: root, cancellation: cancellation) { index, _, _ in
            if index == 1 { cancellation.cancel() }
        }
        preconditionFailure("cancelled Glue must not publish partial results")
    } catch is CancellationError {}
    let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Stems").path).sorted()
    precondition(remainingFiles == baseline)
    var failedTrack = midiTrack
    failedTrack.clips = [AudioClip(id: midi.id, name: "Missing", startTime: 0, duration: 1, audioFile: AudioFile(path: "missing.wav"))]
    multiple.tracks[1] = failedTrack
    do {
        _ = try ItemReRender.glueSelection(project: fixture, song: multiple, ids: selection, directory: root, cancellation: AudioExportCancellation())
        preconditionFailure("failed Glue must not publish partial results")
    } catch {}
    let filesAfterFailure = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Stems").path).sorted()
    precondition(filesAfterFailure == baseline)
    precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.wav").path))
    precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.wav").path))
    precondition(track.clips == clips && multiple.tracks[0].clips == clips)
    print("AUDIO_GLUE_SUM_GAPS_ITEM_FX_TRACK_FX_ONCE_TEMPO_REOPEN_SINGLE_ITEM_CANCEL_ERROR_ROLLBACK_OK")
}

do {
    var fixture = Project.empty(name: "Item tuner print")
    var track = Track(id: UUID(), name: "Tuned", role: .keys)
    var clip = AudioClip(id: UUID(), name: "a.wav", startTime: 0, duration: 1, audioFile: AudioFile(path: "a.wav"))
    clip.pitchSemitones = 12; track.clips = [clip]; fixture.songs[0].tracks = [track]
    let rerendered = try ItemReRender.render(project: fixture, song: fixture.songs[0], track: track, clip: clip, directory: root,
        settings: MediaProcessingFormat(format: .wav, bitDepth: 24, bitrate: 320), cancellation: AudioExportCancellation())
    let glued = try ItemReRender.glue(project: fixture, song: fixture.songs[0], track: track, clips: [clip], directory: root,
        cancellation: AudioExportCancellation())
    for printed in [rerendered, glued] {
        precondition(printed.pitchSemitones == nil, "Tuner resets after printing")
        let pcm = try renderedPCM(root.appendingPathComponent(printed.audioFile!.path))
        let begin = 14400, end = 38400
        var crossings = 0
        for index in (begin + 1)..<end { if pcm[index - 1] < 0 && pcm[index] >= 0 { crossings += 1 } }
        let frequency = Double(crossings) * 48000 / Double(end - begin)
        precondition(abs(frequency - 0.13 * 48000 / (2 * .pi) * 2) < 10, "Printed octave must be audible: \(frequency)")
    }
    let midi = AudioClip(id: UUID(), name: "Later MIDI", startTime: 1.2, duration: 0.5,
        midi: MIDIItem(notes: [MIDINote(start: 0, length: 0.5, pitch: 60, velocity: 100)]))
    track.clips = [clip, midi]; fixture.songs[0].tracks = [track]
    let mixed = try ItemReRender.glue(project: fixture, song: fixture.songs[0], track: track, clips: [midi, clip], directory: root,
        cancellation: AudioExportCancellation())
    precondition(mixed.midi == nil && mixed.audioFile != nil && mixed.frozenMIDI == true && mixed.pitchSemitones == nil)
    precondition(abs(mixed.duration - 1.7) < 0.000001 && mixed.startTime == 0, "Mixed glue spans items and gaps")
    let pcm = try renderedPCM(root.appendingPathComponent(mixed.audioFile!.path))
    precondition(pcm[14400..<38400].contains { abs($0) > 0.001 }, "Mixed glue preserves the audio item")
    precondition(pcm[65000..<78000].allSatisfy { abs($0) < 0.00001 }, "MIDI without an instrument prints silence")
    let notes = try ItemReRender.glue(project: fixture, song: fixture.songs[0], track: track, clips: [midi], directory: root,
        cancellation: AudioExportCancellation())
    precondition(notes.midi != nil && notes.audioFile == nil, "MIDI-only glue remains editable MIDI")
    if let source = ProcessInfo.processInfo.environment["JARAS_TEST_SF2"] {
        var fx = NativeFXSettings()
        var parameters = InstrumentParameters()
        parameters.attack = 0.001; parameters.hold = 0; parameters.decay = 0.001; parameters.sustain = 1; parameters.release = 0.01
        let key = fx.appendNative("Instruments", instrument: "fixture", parameters: parameters)
        track.fx = fx; fixture.songs[0].tracks = [track]
        let instruments = [key: OfflineMIDIInstrument(url: URL(fileURLWithPath: source), parameters: parameters, drums: false, monophonic: false)]
        let mixedWithInstrument = try ItemReRender.glue(project: fixture, song: fixture.songs[0], track: track, clips: [midi, clip], directory: root,
            cancellation: AudioExportCancellation(), instruments: instruments)
        let played = try renderedPCM(root.appendingPathComponent(mixedWithInstrument.audioFile!.path))
        precondition(played[65000..<68000].contains { abs($0) > 0.0001 }, "Mixed glue renders the instrument at the later MIDI position")
        precondition(mixedWithInstrument.frozenMIDI == true, "Printed track FX cannot apply twice")
        print("MIXED_GLUE_WITH_LIVE_INSTRUMENT_OK")
    }
    print("ITEM_TUNER_PRINT_RESET_AND_MIXED_GLUE_AUDIO_MIDI_GAPS_OK")
}

do {
    let videos = root.appendingPathComponent("Videos")
    try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: root.appendingPathComponent("a.wav"), to: videos.appendingPathComponent("soundtrack.wav"))
    var fixture = Project.empty(name: "Movie mix print")
    var track = Track(id: UUID(), name: "Movie track", role: .other)
    let original = AudioClip(id: UUID(), name: "Soundtrack", startTime: 0, duration: 1,
        audioFile: AudioFile(path: "Videos/soundtrack.wav"), phaseInverted: true, pan: -1)
    track.clips = [original]; fixture.songs[0].tracks = [track]
    let result = try ItemReRender.render(project: fixture, song: fixture.songs[0], track: track, clip: original, directory: root,
        settings: MediaProcessingFormat(format: .wav, bitDepth: 24, bitrate: 320), cancellation: AudioExportCancellation())
    precondition(!result.isProjectionMedia && result.audioFile!.path.hasPrefix("Stems/"))
    precondition(result.phaseInverted == nil && result.pan == nil && result.fx == nil)
    let file = try AVAudioFile(forReading: root.appendingPathComponent(result.audioFile!.path))
    let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: pcm)
    let originalFile = try AVAudioFile(forReading: root.appendingPathComponent("a.wav"))
    let originalPCM = AVAudioPCMBuffer(pcmFormat: originalFile.processingFormat, frameCapacity: AVAudioFrameCount(originalFile.length))!
    try originalFile.read(into: originalPCM)
    for i in 1000..<45000 {
        precondition(abs(pcm.floatChannelData![1][i]) < 0.00001)
        precondition(abs(pcm.floatChannelData![0][i] + originalPCM.floatChannelData![0][i]) < 0.0001)
    }
    precondition(FileManager.default.fileExists(atPath: videos.appendingPathComponent("soundtrack.wav").path))
    print("MEDIA_RERENDER_STEMS_ITEM_PHASE_PAN_BAKED_RESET_AND_ORIGINAL_PRESERVED_PCM_OK")
}
