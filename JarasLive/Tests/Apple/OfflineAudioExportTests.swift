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
    precondition(a.audioFile?.path == "Steams/click-01.wav")
    let audio = try AVAudioFile(forReading: root.appendingPathComponent(a.audioFile!.path))
    let pcm = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
    try audio.read(into: pcm)
    let maximum = (0..<Int(pcm.frameLength)).map { abs(pcm.floatChannelData![0][$0]) }.max()!
    precondition(abs(maximum - 0.05) < 0.003, "freeze bakes normalization and item gain once while leaving track volume, pan and mute live")
    let b = try ItemReRender.render(project: freeze, song: freeze.songs[0], track: channel, clip: original, directory: root,
                                  settings: MediaProcessingFormat(format: .aiff, bitDepth: 32, bitrate: 320), cancellation: AudioExportCancellation())
    precondition(b.audioFile?.path == "Steams/click-01.aiff")
    let c = try ItemReRender.render(project: freeze, song: freeze.songs[0], track: channel, clip: a, directory: root,
                                  settings: MediaProcessingFormat(format: .wav, bitDepth: 24, bitrate: 320), cancellation: AudioExportCancellation())
    precondition(c.audioFile?.path == "Steams/click-02.wav")
    precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent(original.audioFile!.path).path))
    precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent(a.audioFile!.path).path), "all previous sources remain available for Undo")
    print("FREEZE_ITEM_GAIN_ONCE_SOURCE_PRESERVATION_EXACT_POSITION_AND_SEQUENTIAL_SUFFIX_OK")
}
try verifyFrozenItem()
