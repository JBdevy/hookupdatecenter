import Foundation
import AVFoundation

setbuf(stdout, nil)
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offline-instrument-\(UUID())")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
func check(_ value: Bool, _ message: String) {
    guard value else { fputs(message + "\n", stderr); exit(1) }
}
func pcm(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}
func export(_ project: Project, start: Double = 0, end: Double = 1.5, minimumClipStart: Double? = nil,
            legacy: [String: OfflineMIDIInstrument]? = nil, instruments: [UUID: [String: OfflineMIDIInstrument]] = [:]) throws -> [Float] {
    let output = folder.appendingPathComponent(UUID().uuidString)
    let job = AudioExportJob(id: "master", fileName: "mix.wav", start: start, end: end, minimumClipStart: minimumClipStart)
    try OfflineAudioExport.run(project: project, song: project.songs[0], plan: AudioExportPlan(jobs: [job]), mediaDirectory: folder,
        outputDirectory: output, sampleRate: 48000, encoding: AudioExportEncoding(bitDepth: 32), cancellation: AudioExportCancellation(),
        midiInstruments: legacy, includeHardwareOutputs: true, midiInstrumentsByTrack: instruments) { _ in }
    return try pcm(output.appendingPathComponent(job.fileName))
}
func note(_ start: Double, _ duration: Double, pitch: Int = 60, muted: Bool = false) -> AudioClip {
    AudioClip(id: UUID(), name: "MIDI", startTime: start, duration: duration, muted: muted,
        midi: MIDIItem(notes: [MIDINote(start: 0, length: duration * 2, pitch: pitch, velocity: 100)], sourceBPM: 120))
}
func near(_ values: [Float], from: Double, to: Double, value: Float, tolerance: Float = 0.00002, _ message: String) {
    let samples = values[Int(from * 48000)..<Int(to * 48000)]
    check(samples.allSatisfy { abs($0 - value) < tolerance }, "\(message), range=\(samples.min()!)...\(samples.max()!) expected=\(value)")
}

#if os(macOS)
let path = ProcessInfo.processInfo.environment["JARAS_TEST_VST3"]!
var scanError: NSError?
let description = JarasVST3.scan(path, error: &scanError)[0]
var project = Project.empty(name: "Multi-clip multitrack VST3")
var first = Track(id: UUID(), name: "First MIDI", role: .keys)
var second = Track(id: UUID(), name: "Second MIDI", role: .keys)
for index in 0..<2 {
    let plugin = ExternalPlugin(classID: description["classID"] as! String, name: "Gain fixture", path: path)
    var fx = NativeFXSettings(); fx.externalPlugins = [plugin]; fx.inserted = [plugin.effectKey]
    if index == 0 { first.fx = fx } else { second.fx = fx }
}
first.outputs = [.stereo]
first.clips = [note(0.1, 0.2), note(0.7, 0.2), note(1.1, 0.2, muted: true)]
second.outputs = [OutputPatch(firstChannel: 3, channelCount: 2)]
second.volume = 0.5; second.clips = [note(0.4, 0.2)]
project.songs[0].tracks = [first, second]; project.songs[0].duration = 1.5
let before = project
let rendered = try export(project)
near(rendered, from: 0.12, to: 0.28, value: 0.125, "first clip must reach VST3 without a native instrument map")
near(rendered, from: 0.42, to: 0.58, value: 0.0625, "second track keeps an independent sequence and fader")
near(rendered, from: 0.72, to: 0.88, value: 0.125, "later clip must not overwrite the first clip's sequence")
near(rendered, from: 0.92, to: 1.45, value: 0, "note offs and muted clips leave silence")
let child = try export(project, start: 0.65, end: 1, minimumClipStart: 0.65)
near(child, from: 0.07, to: 0.23, value: 0.125, "region origin trims the track sequence")
near(child, from: 0, to: 0.04, value: 0, "previous clips cannot leak into a child region")
check(project == before, "export must not mutate track patches, instrument state, or MIDI")
print("OFFLINE_VST3_NO_NATIVE_MAP_MULTICLIP_MULTITRACK_REGION_CLOCK_MUTE_AND_NOTE_OFF_OK")
#endif

if let source = ProcessInfo.processInfo.environment["JARAS_TEST_SF2"] {
    var project = Project.empty(name: "Per-track SF2 maps")
    var fx = NativeFXSettings()
    var parameters = InstrumentParameters()
    parameters.attack = 0.001; parameters.hold = 0; parameters.decay = 0.001; parameters.sustain = 1; parameters.release = 0.005
    let key = fx.appendNative("Instruments", instrument: "fixture", parameters: parameters)
    var a = Track(id: UUID(), name: "A", role: .keys), b = Track(id: UUID(), name: "B", role: .keys)
    a.fx = fx; b.fx = fx; a.outputs = [.stereo]; b.outputs = [.stereo]
    a.clips = [note(0.1, 0.25), note(0.7, 0.25)]
    b.clips = [note(0.1, 0.25), note(0.7, 0.25)]
    let normal = OfflineMIDIInstrument(url: URL(fileURLWithPath: source), parameters: parameters, drums: false, monophonic: false)
    var quietParameters = parameters; quietParameters.gain -= 12
    let quiet = OfflineMIDIInstrument(url: normal.url, parameters: quietParameters, drums: false, monophonic: false)
    project.songs[0].tracks = [a]; project.songs[0].duration = 1.5
    let baseline = try export(project, legacy: [key: normal])
    check(baseline[Int(0.12 * 48000)..<Int(0.3 * 48000)].contains { abs($0) > 0.0001 }, "SF2 first clip must sound")
    check(baseline[Int(0.72 * 48000)..<Int(0.9 * 48000)].contains { abs($0) > 0.0001 }, "SF2 second clip must sound")
    project.songs[0].tracks = [a, b]
    let both = try export(project, legacy: [key: normal], instruments: [b.id: [key: quiet]])
    let gain = Float(1 + pow(10, -12.0 / 20))
    let error = zip(baseline, both).map { abs($0 * gain - $1) }.max()!
    check(error < 0.0001, "per-track map overrides identical instrument slot keys while the legacy source remains available: \(error)")
    print("OFFLINE_SF2_PER_TRACK_SAME_SLOT_LEGACY_FALLBACK_AND_TWO_CLIPS_PCM_OK")
    func freezeMIDI(phase: Bool) throws -> [Float] {
        var track = a; track.phaseInverted = phase
        var fixture = project; fixture.songs[0].tracks = [track]
        let frozen = try ItemReRender.renderMIDI(project: fixture, song: fixture.songs[0], track: track,
            clip: track.clips[0], directory: folder, channels: 2, instruments: [key: normal], cancellation: AudioExportCancellation())
        return try pcm(folder.appendingPathComponent(frozen.audioFile!.path))
    }
    let positiveFreeze = try freezeMIDI(phase: false), negativeFreeze = try freezeMIDI(phase: true)
    check(positiveFreeze.contains { abs($0) > 0.0001 } && zip(positiveFreeze, negativeFreeze).allSatisfy { abs($0 - $1) < 0.000001 },
        "MIDI freeze leaves track polarity live instead of applying it twice after conversion")
    print("OFFLINE_MIDI_FREEZE_TRACK_POLARITY_REMAINS_LIVE_PCM_OK")

    var releaseParameters = parameters; releaseParameters.release = 0.3
    var releaseFX = NativeFXSettings()
    let releaseKey = releaseFX.appendNative("Instruments", instrument: "fixture", parameters: releaseParameters)
    var releaseTrack = a; releaseTrack.fx = releaseFX
    releaseTrack.clips = [AudioClip(id: UUID(), name: "Release crossing selection", startTime: 0, duration: 1,
        midi: MIDIItem(notes: [MIDINote(start: 0.4, length: 0.1, pitch: 60, velocity: 100)], sourceBPM: 120))]
    project.songs[0].tracks = [releaseTrack]
    let releaseSource = OfflineMIDIInstrument(url: normal.url, parameters: releaseParameters, drums: false, monophonic: false)
    let release = try export(project, start: 0.27, end: 0.5, instruments: [releaseTrack.id: [releaseKey: releaseSource]])
    check(release.prefix(2400).contains { abs($0) > 0.0001 },
        "a note ending in the preroll keeps its audible instrument release at the selected region start")
    project.songs[0].tracks[0].clips[0].duration = 0.25
    let afterItem = try export(project, start: 0.27, end: 0.5, instruments: [releaseTrack.id: [releaseKey: releaseSource]])
    check(afterItem.count == release.count && zip(afterItem, release).allSatisfy { abs($0 - $1) < 0.000001 },
        "the same release survives when its item also ends in the preroll")
    print("OFFLINE_MIDI_PREROLL_RELEASE_CROSSING_SELECTION_START_PCM_OK")
}

// Use a real decoded one-shot and the live generator's musical origin. Two
// overlapping click items merge; they must not double either attack.
let rate = 48000.0
let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
let sound = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
sound.frameLength = 480
for sample in 0..<480 { sound.floatChannelData![0][sample] = sample < 200 ? 0.25 : 0 }
let soundURL = folder.appendingPathComponent("click.wav")
do { let file = try AVAudioFile(forWriting: soundURL, settings: format.settings); try file.write(from: sound) }
var clickProject = Project.empty(name: "Generated click export")
var clickTrack = Track(id: UUID(), name: "Click", role: TrackRole(rawValue: "generatedClick"))
clickTrack.outputs = [.stereo]; clickTrack.volume = 0.5; clickTrack.clickSound = AudioFile(path: "click.wav")
clickTrack.clips = [AudioClip(id: UUID(), name: "First", startTime: 0.25, duration: 0.8),
    AudioClip(id: UUID(), name: "Overlap", startTime: 0.75, duration: 0.6)]
clickProject.songs[0].tracks = [clickTrack]; clickProject.songs[0].duration = 1.5; clickProject.songs[0].bpm = 120
clickProject.songs[0].markers = [TimelineMarker(id: UUID(), name: "Faster", position: 1, color: 0, tempoBPM: 240)]
let click = try export(clickProject)
for onset in [0.5, 1.0, 1.25] {
    near(click, from: onset + 0.001, to: onset + 0.003, value: 0.125, "generated click at musical onset \(onset)")
}
near(click, from: 0, to: 0.49, value: 0, "click keeps tempo origin rather than starting at item edge")
near(click, from: 1.36, to: 1.49, value: 0, "generated click stops at its item boundary")
let selectedClick = try export(clickProject, start: 0.4, end: 1.4)
near(selectedClick, from: 0.101, to: 0.103, value: 0.125, "nonzero export start retains original click origin")
let drawerClick = try export(clickProject, start: 0.4, end: 1.4, minimumClipStart: 0.4)
check(drawerClick.count == selectedClick.count && zip(drawerClick, selectedClick).allSatisfy { abs($0 - $1) < 0.000001 },
    "drawer exports retain their shared parent click while the onset cutoff still excludes prior stems")
clickProject.songs[0].tracks[0].phaseInverted = true
let invertedClick = try export(clickProject)
check(zip(click, invertedClick).allSatisfy { abs($0 + $1) < 0.00001 }, "click track phase applies to the generated signal")
clickProject.songs[0].tracks[0].mute = true
check(try export(clickProject).allSatisfy { abs($0) < 0.000001 }, "click track mute gates export")
print("OFFLINE_REAL_CLICK_GENERATOR_TEMPO_OVERLAP_RANGE_GAIN_PHASE_AND_MUTE_PCM_OK")

func freezeAudio(phase: Bool, glue: Bool) throws -> [Float] {
    var project = Project.empty(name: "Preserve live track polarity")
    var track = Track(id: UUID(), name: "Audio", role: .other)
    track.phaseInverted = phase
    track.clips = [AudioClip(id: UUID(), name: "First", startTime: 0, duration: 0.01, audioFile: AudioFile(path: "click.wav")),
        AudioClip(id: UUID(), name: "Second", startTime: 0.02, duration: 0.01, audioFile: AudioFile(path: "click.wav"))]
    project.songs[0].tracks = [track]
    let result: AudioClip
    if glue {
        result = try ItemReRender.glue(project: project, song: project.songs[0], track: track, clips: track.clips,
            directory: folder, cancellation: AudioExportCancellation())
    } else {
        result = try ItemReRender.render(project: project, song: project.songs[0], track: track, clip: track.clips[0],
            directory: folder, settings: MediaProcessingFormat(format: .wav, bitDepth: 32, bitrate: 320), cancellation: AudioExportCancellation())
    }
    return try pcm(folder.appendingPathComponent(result.audioFile!.path))
}
for glue in [false, true] {
    let positive = try freezeAudio(phase: false, glue: glue), negative = try freezeAudio(phase: true, glue: glue)
    let error = zip(positive, negative).map { abs($0 - $1) }.max() ?? 0
    check(positive.count == negative.count && positive.contains { $0 > 0.05 } && error < 0.000001,
        "audio freeze/glue preserves live track polarity, glue=\(glue), peak=\(positive.max() ?? 0), error=\(error)")
}
print("OFFLINE_AUDIO_FREEZE_AND_GLUE_TRACK_POLARITY_REMAINS_LIVE_PCM_OK")
