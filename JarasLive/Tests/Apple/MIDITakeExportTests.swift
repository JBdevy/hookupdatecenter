import Foundation
import AVFoundation
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
guard let path = ProcessInfo.processInfo.environment["JARAS_TEST_VST3"] else { fatalError("Set JARAS_TEST_VST3 to GainFixture.vst3") }
let rate = 48000.0
var scanError: NSError?
let descriptor = JarasVST3.scan(path, error: &scanError)[0]
let classID = descriptor["classID"] as! String
func plugin(_ instrument: Bool = false) -> ExternalPlugin { ExternalPlugin(classID: classID, name: "Fixture", path: path, category: instrument ? "Instrument|Synth" : "Fx") }
func chain(_ plugins: [ExternalPlugin]) -> NativeFXSettings {
    var fx = NativeFXSettings(); fx.externalPlugins = plugins; fx.inserted = plugins.map(\.effectKey); return fx
}
func samples(_ url: URL, _ channel: Int = 0) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: pcm)
    return Array(UnsafeBufferPointer(start: pcm.floatChannelData![channel], count: Int(pcm.frameLength)))
}
func rms(_ samples: [Float], _ time: Double) -> Double {
    let first = Int(time * rate), count = 2400
    return sqrt(samples[first..<first+count].reduce(0) { $0 + Double($1*$1) } / Double(count))
}
let instrument = plugin(true), effect = plugin()
var clip = AudioClip(id: UUID(), name: "MIDI take", startTime: 0, duration: 3, gain: 0.4, pan: -1,
    fx: chain([instrument,effect]), midi: MIDIItem(notes: [MIDINote(start: 0, length: 6, pitch: 60, velocity: 100)], sourceBPM: 120))
var track = Track(id: UUID(), name: "Take track", role: .other); track.clips = [clip]
var project = Project.empty(name: "Take VST3i export"); project.songs[0].tracks = [track]
func render(_ project: Project, _ name: String) throws -> URL {
    let job = AudioExportJob(id: name, fileName: name + ".wav", start: 0, end: 4, track: nil, clip: nil)
    let folder = root.appendingPathComponent(name)
    try OfflineAudioExport.run(project: project, song: project.songs[0], plan: AudioExportPlan(jobs: [job]), mediaDirectory: root,
        outputDirectory: folder, sampleRate: rate, cancellation: AudioExportCancellation()) { _ in }
    return folder.appendingPathComponent(job.fileName)
}
let baselineURL = try render(project,"baseline"), baseline = try samples(baselineURL)
print("OFFLINE_MIDI_TAKE_BASELINE", rms(baseline,0.5))
let baselineRight = try samples(baselineURL,1)
precondition(abs(rms(baseline,0.5)-0.025)<0.001 && rms(baselineRight,0.5)<1e-6, "Offline take instrument needs no track instrument and honors gain/pan")
precondition(rms(baseline,3.3)<1e-6,"Offline note ends at take boundary")
var neighbour = clip; neighbour.id = UUID(); neighbour.gain = 0.2; neighbour.pan = 1
var inactive = clip; inactive.id = UUID(); inactive.muted = true
project.songs[0].tracks[0].clips += [neighbour,inactive]
let isolatedURL = try render(project,"isolated")
let isolatedLeft = try samples(isolatedURL), isolatedRight = try samples(isolatedURL,1)
precondition(abs(rms(isolatedLeft,0.5)/rms(baseline,0.5)-1)<0.01 && abs(rms(isolatedRight,0.5)/rms(baseline,0.5)-0.5)<0.01,
             "Offline overlapping takes preserve plugin isolation and inactive takes stay silent")
project.songs[0].tracks[0].clips = [clip]; project.songs[0].tracks[0].fx = chain([plugin()])
let trackFX = try samples(render(project,"trackFX"))
precondition(abs(rms(trackFX,0.5)/rms(baseline,0.5)-0.5)<0.01,"Offline take PCM must route through track FX")
var automation = TrackAutomation()
var volume = TrackEnvelope(target: AutomationTarget(.volume), name: "Take gain", defaultValue: TrackEnvelope.normalizedGain(1))
volume.points = [.init(time: 0, value: TrackEnvelope.normalizedGain(1), shape: .square), .init(time: 1, value: TrackEnvelope.normalizedGain(0.5), shape: .square)]
var external = TrackEnvelope(target: AutomationTarget(.externalFX, plugin: effect.id, parameter: 0), name: "Take FX gain", defaultValue: 0.5)
external.points = [.init(time: 0, value: 0.8, shape: .square), .init(time: 1, value: 0.2, shape: .square)]
automation.envelopes = [volume,external]; clip.automation = automation; track.clips = [clip]; track.fx = nil
project.songs[0].tracks = [track]
let automated = try samples(render(project,"automated"))
precondition(abs(rms(automated,0.5)/rms(automated,1.5)-8)<0.05,"Offline MIDI take envelopes apply to generated audio and its own FX")
let frozen = try ItemReRender.renderMIDI(project: project, song: project.songs[0], track: track, clip: clip, directory: root,
    channels: 2, instruments: [:], cancellation: AudioExportCancellation())
precondition(frozen.midi == nil && frozen.fx == nil && frozen.automation == nil && frozen.automationSourceOffset == nil && frozen.frozenMIDI == true,
             "MIDI freeze must bake and clear take FX and automation")
let frozenPCM = try samples(root.appendingPathComponent(frozen.audioFile!.path))
precondition(abs(rms(frozenPCM,0.5)/rms(frozenPCM,1.5)-8)<0.05,"MIDI freeze contains take instrument and envelopes")
// Mixed glue must not collapse distinct take FX into an uninstrumented item.
let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144000)!; silence.frameLength = silence.frameCapacity
for c in 0..<2 { for i in 0..<Int(silence.frameLength) { silence.floatChannelData![c][i] = 0 } }
do { let file = try AVAudioFile(forWriting: root.appendingPathComponent("silence.wav"), settings: format.settings); try file.write(from: silence) }
let audio = AudioClip(id: UUID(), name: "Audio", startTime: 0, duration: 3, audioFile: AudioFile(path: "silence.wav"))
track.clips = [clip,audio]; project.songs[0].tracks = [track]
let glued = try ItemReRender.glue(project: project, song: project.songs[0], track: track, clips: track.clips, directory: root, cancellation: AudioExportCancellation())
let gluedPCM = try samples(root.appendingPathComponent(glued.audioFile!.path))
precondition(glued.fx == nil && glued.automation == nil && abs(rms(gluedPCM,0.5)/rms(gluedPCM,1.5)-8)<0.05,
             "Mixed audio/MIDI glue must preserve then bake take instrument and its own envelopes")
print("OFFLINE_MIDI_TAKE_INSTRUMENT_ISOLATION_TRACK_FX_ENV_FREEZE_MIXED_GLUE_PCM_OK")
