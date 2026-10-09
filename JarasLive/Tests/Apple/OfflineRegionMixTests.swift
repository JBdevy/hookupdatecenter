import Foundation
import AVFoundation

// Standalone PCM integration fixture for the opt-in mix of audible hardware
// outputs. Run through scripts/test-offline-export.sh with CATLIVE_EXPORT_TEST_SOURCE.
setbuf(stdout, nil)
let root = FileManager.default.temporaryDirectory.appendingPathComponent("region-mix-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
AudioLicenseAccess.shared.setAllowed(true)
let sampleRate = 48000.0
let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 96000)!
source.frameLength = 96000
for frame in 0..<96000 {
    source.floatChannelData![0][frame] = 0.2 * sin(Float(Double(frame) * 2 * .pi * 100 / sampleRate))
    source.floatChannelData![1][frame] = 0.12 * sin(Float(Double(frame) * 2 * .pi * 150 / sampleRate))
}
do {
    let sourceFile = try AVAudioFile(forWriting: root.appendingPathComponent("tone.wav"), settings: sourceFormat.settings)
    try sourceFile.write(from: source)
}

struct PCM {
    let channels: [[Float]]
    var frames: Int { channels[0].count }
    var peak: Float { channels.flatMap { $0 }.map { abs($0) }.max() ?? 0 }
    func slice(_ range: Range<Int>) -> PCM { PCM(channels: channels.map { Array($0[range]) }) }
}
func readPCM(_ url: URL) throws -> PCM {
    let file = try AVAudioFile(forReading: url)
    precondition(file.processingFormat.sampleRate == sampleRate && file.processingFormat.channelCount == 2)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return PCM(channels: (0..<2).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength))) })
}
func equalPCM(_ actual: PCM, _ expected: PCM, _ message: String, gain: Float = 1, tolerance: Float = 0.00002) {
    precondition(actual.frames == expected.frames, "\(message): duration differs (\(actual.frames) vs \(expected.frames))")
    var error: Float = 0
    for channel in 0..<2 {
        for frame in 0..<actual.frames { error = max(error, abs(actual.channels[channel][frame] - expected.channels[channel][frame] * gain)) }
    }
    precondition(error <= tolerance, "\(message): maximum PCM error \(error)")
}
func clip(_ start: Double = 0.1, _ duration: Double = 0.8, gain: Double = 1) -> AudioClip {
    AudioClip(id: UUID(), name: "Tone", startTime: start, duration: duration, audioFile: AudioFile(path: "tone.wav"), gain: gain)
}
func fixture(_ tracks: [Track]) -> Project {
    var project = Project.empty(name: "Region mix")
    project.songs[0].duration = 2
    project.songs[0].tracks = tracks
    return project
}
func export(_ project: Project, _ name: String, includeHardware: Bool = true, plan suppliedPlan: AudioExportPlan? = nil) throws -> [PCM] {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let projectBefore = try encoder.encode(project)
    let song = project.songs[0]
    let plan = suppliedPlan ?? AudioExportPlan(jobs: [AudioExportJob(id: "master", fileName: "Master.wav", start: 0, end: 1, track: nil, clip: nil)])
    let destination = root.appendingPathComponent(name)
    try OfflineAudioExport.run(project: project, song: song, plan: plan, mediaDirectory: root,
        outputDirectory: destination, sampleRate: sampleRate, cancellation: AudioExportCancellation(),
        includeHardwareOutputs: includeHardware) { _ in }
    let projectAfter = try encoder.encode(project)
    precondition(projectAfter == projectBefore, "export must preserve source tracks, clips, regions and mixer settings")
    return try plan.jobs.map { try readPCM(destination.appendingPathComponent($0.fileName)) }
}

var group = Track(id: UUID(), name: "Group", role: .other)
group.volume = 0.4; group.outputs = [.master]
var child = Track(id: UUID(), name: "Child", role: .other)
child.parentTrackID = group.id; child.volume = 0.5; child.outputs = [.masterGroup]
child.clips = [clip(gain: 0.6)]
let referenceProject = fixture([group, child])
let reference = try export(referenceProject, "group-master-reference", includeHardware: false)[0]
precondition(reference.frames == 48000 && reference.peak > 0.02, "Master reference must contain real processed PCM")
precondition(reference.channels.allSatisfy { $0.prefix(4000).allSatisfy { abs($0) < 0.000001 } }, "leading timeline silence is retained")

var hardwareProject = referenceProject
hardwareProject.songs[0].tracks[0].outputs = [OutputPatch(firstChannel: 5, channelCount: 2)]
equalPCM(try export(hardwareProject, "group-hardware")[0], reference,
    "child to group to hardware must preserve child and group gain and stereo PCM")
let hardwareOptOut = try export(hardwareProject, "group-hardware-opt-out", includeHardware: false)[0]
precondition(hardwareOptOut.peak < 0.000001,
    "the ordinary Master export must still exclude direct hardware outputs")
print("REGION_MIX_HARDWARE_GROUP_ANCESTRY_AND_OPT_IN_PCM_OK")

var multipleOutputs = hardwareProject
multipleOutputs.songs[0].tracks[0].outputs = [.master, .stereo, OutputPatch(firstChannel: 7, channelCount: 2)]
equalPCM(try export(multipleOutputs, "multiple-hardware-and-master")[0], reference,
    "one bus with Master and multiple hardware destinations must enter the exported root only once")
var noneTrack = Track(id: UUID(), name: "Disconnected", role: .other)
noneTrack.outputs = [.none]; noneTrack.clips = [clip(0, 1, gain: 2)]
var withDisconnected = hardwareProject
withDisconnected.songs[0].tracks.append(noneTrack)
equalPCM(try export(withDisconnected, "disconnected-track")[0], reference,
    "a None-only track without an explicit connection must not contaminate the exported mix")
var noneGroup = hardwareProject
noneGroup.songs[0].tracks[0].outputs = [.none]
let disconnectedGroup = try export(noneGroup, "disconnected-group")[0]
precondition(disconnectedGroup.peak < 0.000001,
    "children routed only through a disconnected group must remain inaudible")
print("REGION_MIX_MULTIPLE_OUTPUTS_DEDUP_AND_NONE_PCM_OK")

var sender = Track(id: UUID(), name: "Explicit sender", role: .other)
sender.outputs = [.none]; sender.volume = 0.5; sender.clips = [clip()]
var receiver = Track(id: UUID(), name: "Explicit receiver", role: .other)
receiver.outputs = [.master]; receiver.volume = 0.25
sender.routing = TrackRouting(transmitters: [receiver.id])
receiver.routing = TrackRouting(receives: [sender.id])
let routedReference = try export(fixture([sender, receiver]), "explicit-master-reference", includeHardware: false)[0]
precondition(routedReference.peak > 0.02, "explicit routing reference must be audible")
receiver.outputs = [OutputPatch(firstChannel: 9, channelCount: 2)]
equalPCM(try export(fixture([sender, receiver]), "explicit-hardware")[0], routedReference,
    "hardware roots must pull connected sources and deduplicate Receive/Transmitter declarations")
var duplicateParentEdge = hardwareProject
duplicateParentEdge.songs[0].tracks[1].routing = TrackRouting(transmitters: [group.id])
duplicateParentEdge.songs[0].tracks[0].routing = TrackRouting(receives: [child.id])
equalPCM(try export(duplicateParentEdge, "parent-and-explicit-edge")[0], reference,
    "an explicit connection already represented by Master Group must not double the child")
print("REGION_MIX_EXPLICIT_CONNECTIONS_AND_PARENT_EDGE_DEDUP_PCM_OK")

var positive = Track(id: UUID(), name: "Positive", role: .other)
positive.outputs = [.stereo]; positive.clips = [clip(0, 1)]
var negative = positive
negative.id = UUID(); negative.name = "Inverted"; negative.clips[0].id = UUID()
negative.phaseInverted = true
let cancellation = try export(fixture([positive, negative]), "track-phase-cancellation")[0]
precondition(cancellation.peak < 0.00002, "opposite track polarity must cancel sample-for-sample in the hardware mix")
var parentPhase = hardwareProject
parentPhase.songs[0].tracks[0].phaseInverted = true
equalPCM(try export(parentPhase, "parent-phase")[0], reference,
    "parent group polarity must invert its processed descendants once", gain: -1)
print("REGION_MIX_TRACK_AND_PARENT_POLARITY_PCM_OK")

var masterGain = hardwareProject
masterGain.masterVolume = 0.25
equalPCM(try export(masterGain, "master-gain")[0], reference,
    "hardware contributions must pass through the Master fader exactly once", gain: 0.25)
var masterMute = hardwareProject
masterMute.masterMute = true
let mutedMaster = try export(masterMute, "master-mute")[0]
precondition(mutedMaster.peak < 0.000001,
    "Master mute must silence hardware contributions to the rendered mix")
var gainFX = NativeFXSettings()
gainFX.compressorEnabled = true; gainFX.ratio = 1; gainFX.threshold = 0; gainFX.makeup = 6
var masterEffects = hardwareProject
masterEffects.masterFX = gainFX
var referenceEffects = referenceProject
referenceEffects.masterFX = gainFX
let referenceEffectsPCM = try export(referenceEffects, "master-fx-reference", includeHardware: false)[0]
precondition(referenceEffectsPCM.peak > reference.peak * 1.8, "Master FX reference must apply its gain")
equalPCM(try export(masterEffects, "master-fx-hardware")[0], referenceEffectsPCM,
    "hardware contributions must use the complete Master FX chain")
var masterMono = hardwareProject
masterMono.masterMono = true
let mono = try export(masterMono, "master-mono")[0]
precondition(mono.peak > 0.01, "Master mono must retain audible content")
precondition(zip(mono.channels[0], mono.channels[1]).allSatisfy { abs($0 - $1) < 0.00002 },
    "Master mono applies to the final hardware-inclusive mix")
print("REGION_MIX_MASTER_GAIN_MUTE_FX_AND_MONO_PCM_OK")

var hardwareMasterSolo = hardwareProject
hardwareMasterSolo.masterSolo = true
let soloHardware = try export(hardwareMasterSolo, "master-solo-hardware-only")[0]
precondition(soloHardware.peak < 0.000001, "Master Solo suppresses a hardware-only bus as in live playback")
var bothMasterSolo = multipleOutputs
bothMasterSolo.masterSolo = true
equalPCM(try export(bothMasterSolo, "master-solo-master-plus-hardware")[0], reference,
    "Master Solo retains a bus that also reaches Master without doubling its hardware paths")
for index in [0, 1] {
    var trackMuted = hardwareProject
    trackMuted.songs[0].tracks[index].mute = true
    let silence = try export(trackMuted, "muted-track-\(index)")[0]
    precondition(silence.peak < 0.000001, "muting either a group or its child silences that hardware branch")
}
for index in [0, 1] {
    var trackSoloed = hardwareProject
    trackSoloed.songs[0].tracks[index].solo = true
    var unrelated = noneTrack
    unrelated.outputs = [.stereo]
    trackSoloed.songs[0].tracks.append(unrelated)
    equalPCM(try export(trackSoloed, "solo-track-\(index)")[0], reference,
        "group/child Solo retains its hierarchy while suppressing an unrelated audible hardware bus")
}
print("REGION_MIX_MASTER_SOLO_TRACK_MUTE_SOLO_AND_PROJECT_IMMUTABILITY_PCM_OK")

var regionTrack = Track(id: UUID(), name: "Region audio", role: .other)
regionTrack.outputs = [.stereo]
regionTrack.clips = [clip(0.2, 1.2), clip(0.7, 0.7, gain: 0.5)]
var regions = fixture([regionTrack])
let unified = Part(id: UUID(), name: "Unified", startTime: 0.2, endTime: 1.4)
let first = Part(id: UUID(), name: "First", startTime: 0.2, endTime: 0.7, parentRegionID: unified.id)
let second = Part(id: UUID(), name: "Second", startTime: 0.7, endTime: 1.4, parentRegionID: unified.id)
regions.songs[0].parts = [unified, first, second]
let regionsPlan = AudioExportPlan(project: regions, song: regions.songs[0], source: .master, bounds: .regions,
    template: "%region", tracks: [], clips: [], regions: [unified.id, first.id, second.id])
precondition(regionsPlan.jobs.count == 3)
let regionPCM = try export(regions, "region-ranges", plan: regionsPlan)
precondition(regionPCM.map(\.frames) == [57600, 24000, 33600], "parent and child WAVs stop at their exact region boundaries")
var masterRegions = regions
masterRegions.songs[0].tracks[0].outputs = [.master]
let expectedRegions = try export(masterRegions, "region-master-reference", includeHardware: false, plan: regionsPlan)
for index in regionPCM.indices {
    equalPCM(regionPCM[index], expectedRegions[index], "hardware mix preserves parent/child range policy for \(regionsPlan.jobs[index].fileName)")
}
equalPCM(regionPCM[1], regionPCM[0].slice(0..<24000), "first child matches its exact parent interval")
var secondOnly = regions
secondOnly.songs[0].tracks[0].clips.removeFirst()
let secondPlan = AudioExportPlan(jobs: [AudioExportJob(id: "second-only", fileName: "Second.wav", start: 0.7, end: 1.4, track: nil, clip: nil)])
equalPCM(regionPCM[2], try export(secondOnly, "second-child-reference", plan: secondPlan)[0],
    "a drawer child excludes the prior song's outgoing stem while its parent retains that stem")
precondition(regionPCM[0].slice(24000..<57600).peak > regionPCM[2].peak * 2,
    "parent export must retain the outgoing stem that crosses into the next child")
print("REGION_MIX_PARENT_CHILD_EXACT_BOUNDARIES_AND_OUTGOING_STEM_PCM_OK")
print("OFFLINE_REGION_MIX_HARDWARE_ROUTING_MASTER_PROCESSING_AND_RANGES_OK")
