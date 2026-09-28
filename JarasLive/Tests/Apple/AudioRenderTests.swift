import Foundation
import AVFoundation
import Darwin
setbuf(stdout, nil)
@MainActor func run() throws {
let meter = TrackMeterLevel()
meter.update(peak: 0.01, elapsed: 1.0 / 30)
precondition(meter.level > 0, "quiet audio must register")
var previousLevel = meter.level
for _ in 0..<120 {
    meter.update(peak: 0, elapsed: 1.0 / 30)
    precondition(meter.level <= previousLevel, "release must descend monotonically")
    previousLevel = meter.level
}
precondition(meter.level == 0, "quiet meter must reach silence instead of freezing")
meter.update(peak: 0.5, elapsed: 1.0 / 30)
precondition(meter.level == 0.5, "new peaks must register immediately")
meter.reset()
meter.update(peak: 0, elapsed: 1.0 / 30)
precondition(meter.level == 0, "stop clears the envelope as well as the display")
meter.update(left: 0.4, right: 0.05, elapsed: 1.0 / 30)
precondition(meter.levels.x == 0.4 && meter.levels.y == 0.05, "stereo meter preserves separate L and R peaks")
meter.reset()
print("METER_RELEASE_OK")
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
do {
    let file = try AVAudioFile(forWriting: directory.appendingPathComponent("tone.wav"), settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441000)!
    buffer.frameLength = 441000
    for c in 0..<2 { for i in 0..<441000 { buffer.floatChannelData![c][i] = 0.1 } }
    try file.write(from: buffer)
}
let engine = AVAudioEngine()
let outputFormat = AVAudioFormat(standardFormatWithSampleRate: Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!, channels: 2)!
try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
let renderer = StemAudioPlayback(engine: engine, realtime: false)
renderer.open(directory: directory)
var project = Project.empty(name: "Audio render test")
let id = UUID()
var track = Track(id: id, name: "Tone", role: .keys)
track.clips = [AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 10, audioFile: AudioFile(path: "tone.wav"))]
project.songs[0].tracks = [track]
var snapshot = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512)!
func peak() throws -> Float {
    var value: Float = 0
    for iteration in 0..<24 {
        let status = try engine.renderOffline(512, to: output)
        if status == .success, iteration > 15 {
            for i in 0..<Int(output.frameLength) { value = max(value, abs(output.floatChannelData![0][i])) }
        }
    }
    return value
}
try renderer.update(snapshot, revision: 1)
// A nonzero first sample must enter smoothly, including when resampled to 48 kHz.
var onsetSamples: [Float] = []
for _ in 0..<2 {
    if try engine.renderOffline(512, to: output) == .success {
        onsetSamples += Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
let maximumStep = zip(onsetSamples, onsetSamples.dropFirst()).map { abs($0 - $1) }.max() ?? 1
precondition(maximumStep < 0.01, "start must not jump from silence to full signal: \(maximumStep)")
let mainPeak = try peak()
precondition(mainPeak > 0.09 && mainPeak < 0.11, "real file audio must reach output: \(mainPeak)")
renderer.previewVolume(id, gain: pow(10, 12.0/20))
let louder = try peak()
precondition(louder > 0.38 && louder < 0.41, "+12 dB must amplify PCM: \(louder)")
snapshot.project.songs[0].tracks[0].mute = true
try renderer.update(snapshot, revision: 2)
let muted = try peak()
precondition(muted < 0.0001, "mute must silence PCM: \(muted)")
renderer.stop()
precondition(!engine.isRunning, "stop suspends the audio engine")
snapshot.project.songs[0].tracks[0].mute = false
snapshot.transport.subPlay.playing = true
snapshot.transport.subPlay.position = 0
snapshot.project.songs[0].followTempo(180)
try renderer.update(snapshot, revision: 3)
let dual = try peak()
precondition(dual > 0.16 && dual < 0.24, "main and subplay mix independent streams: \(dual)")
let gainItemID = snapshot.project.songs[0].tracks[0].clips[0].id
renderer.previewItemGain(gainItemID, gain: 0.25)
let previewDual = try peak()
precondition(previewDual > 0.04 && previewDual < 0.06, "item gain preview changes both heads: \(previewDual)")
renderer.previewItemGain(gainItemID, gain: 0.25)
renderer.previewItemGain(gainItemID, gain: 1)
let restoredDual = try peak()
precondition(restoredDual > 0.16 && restoredDual < 0.24, "item gain preview restores both existing streams: \(restoredDual)")
print("ITEM_GAIN_PREVIEW_PRIMARY_AND_SUBPLAY_OK")
snapshot.transport.subPlayPromotion = 1
snapshot.transport.subPlay.playing = false
try renderer.update(snapshot, revision: 3)
let handoffStatus = try engine.renderOffline(512, to: output)
precondition(handoffStatus == .success, "handoff renders")
let handoffMinimum = (0..<Int(output.frameLength)).map { abs(output.floatChannelData![0][$0]) }.min() ?? 0
precondition(handoffMinimum > 0.07, "promoted subplay must keep its existing stream without silence or a new onset ramp")
let handoffMaximum = (64..<Int(output.frameLength)).map { abs(output.floatChannelData![0][$0]) }.max() ?? 0
precondition(handoffMaximum < 0.13, "promotion stops only the former main stream, without doubling the promoted audio")
print("SUBPLAY_HANDOFF_PCM_OK")
snapshot.project.songs[0].tracks[0].clips[0].muted = true
try renderer.update(snapshot, revision: 4)
renderer.previewItemGain(gainItemID, gain: 2)
let itemMuted = try peak()
precondition(itemMuted < 0.0001, "item gain preview must preserve item mute")
snapshot.project.songs[0].tracks[0].clips[0].muted = false
snapshot.project.masterMute = true
try renderer.update(snapshot, revision: 5)
let masterMuted = try peak()
precondition(masterMuted < 0.0001, "master mute silences output")
snapshot.project.songs[0].tracks[0].patch = .stereo
try renderer.update(snapshot, revision: 6)
let directPeak = try peak()
precondition(directPeak > 0.09 && directPeak < 0.11, "direct output bypasses master mute: \(directPeak)")
snapshot.project.masterVolume = 0.1
snapshot.project.masterMute = false
try renderer.update(snapshot, revision: 7)
let directLowMaster = try peak()
precondition(directLowMaster > 0.09 && directLowMaster < 0.11, "direct output bypasses master fader")
snapshot.project.songs[0].tracks[0].patch = .master
try renderer.update(snapshot, revision: 8)
let throughMaster = try peak()
precondition(throughMaster > 0.009 && throughMaster < 0.011, "master fader affects only tracks routed into master")
print("MASTER_BUS_ROUTING_OK")
renderer.stop()
// Reverb and delay keep processing with the device warm: Stop must clear their
// PCM state, including when both transport heads were active.
snapshot.project.masterVolume = 1
var tailFX = NativeFXSettings()
tailFX.inserted = ["Delay", "Reverb"]
tailFX.delayEnabled = true; tailFX.delayTime = 0.01; tailFX.delayMix = 80; tailFX.feedback = 80
tailFX.reverbEnabled = true; tailFX.reverbMix = 80; tailFX.reverbDecay = 8
snapshot.project.songs[0].tracks[0].fx = tailFX
snapshot.project.masterFX = tailFX
snapshot.transport.playing = true; snapshot.transport.position = 0
snapshot.transport.subPlay.playing = true; snapshot.transport.subPlay.position = 0
try renderer.update(snapshot, revision: 9)
let effectPeak = try peak()
precondition(effectPeak > 0.001, "effect fixture reaches output")
snapshot.transport.playing = false; snapshot.transport.subPlay.playing = false
try renderer.update(snapshot, revision: 9)
// Offline mode pauses for determinism; resume without transport so lingering
// effect audio cannot hide behind a suspended audio device.
try engine.start()
let stoppedPeak = try peak()
precondition(stoppedPeak < 0.000001, "Stop must silence both heads and effect tails: \(stoppedPeak)")
renderer.stop()
print("STOP_MAIN_SUBPLAY_AND_EFFECT_TAILS_OK")
// A later region can introduce tracks that had no source in the first region.
var laterTrack = Track(id: UUID(), name: "Later region", role: .other)
laterTrack.clips = [AudioClip(id: UUID(), name: "Later", startTime: 2, duration: 1, audioFile: AudioFile(path: "tone.wav"))]
snapshot.project.songs[0].tracks[0].fx = nil
snapshot.project.masterFX = nil
snapshot.project.songs[0].tracks.append(laterTrack)
renderer.open(directory: directory)
snapshot.transport.playing = true; snapshot.transport.position = 0; snapshot.transport.subPlay.playing = false
try renderer.update(snapshot, revision: 99)
_ = try peak()
snapshot.transport.playing = false
try renderer.update(snapshot, revision: 99)
snapshot.transport.playing = true; snapshot.transport.position = 2
try renderer.update(snapshot, revision: 99)
let laterPeak = try peak()
precondition(laterPeak > 0.09, "tracks first used in later regions must remain connected: \(laterPeak)")
renderer.stop()
print("LATER_REGION_TRACK_AUDIO_OK")

// Render real stereo PCM through the production scheduler and time stretcher.
// A 440/880 Hz signal lasts three source seconds, followed by one silent second.
do {
    let file = try AVAudioFile(forWriting: directory.appendingPathComponent("tempo.wav"), settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 176400)!
    buffer.frameLength = 176400
    for channel in 0..<2 {
        for frame in 0..<176400 {
            let ramp = min(1, min(Double(frame) / 441, Double(132300-frame) / 441))
            buffer.floatChannelData![channel][frame] = frame < 132300 ? Float(0.1 * max(0,ramp) * sin(2 * .pi * Double(channel == 0 ? 440 : 880) * Double(frame) / 44100)) : 0
        }
    }
    try file.write(from: buffer)
}
func renderTempo(_ rate: Double, change: Bool = false) throws -> [[Float]] {
    renderer.open(directory: directory)
    var project = Project.empty(name: "Tempo PCM")
    var track = Track(id: UUID(), name: "Tempo", role: .other)
    track.clips = [AudioClip(id: UUID(), name: "Stereo", startTime: 0, duration: 4, audioFile: AudioFile(path: "tempo.wav"))]
    project.songs[0].tracks = [track]
    project.songs[0].followTempo(120 * (change ? 1 : rate))
    var state = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    var revision: UInt64 = 200
    var samples = [[Float](), [Float]()]
    var changed = false
    let total = Int(outputFormat.sampleRate * (change ? 3 : 3 / rate + 0.4))
    var position = 0.0
    while samples[0].count < total {
        if change && !changed && samples[0].count >= Int(outputFormat.sampleRate) {
            state.project.songs[0].followTempo(120 * rate)
            position /= rate; revision += 1; changed = true
        }
        state.transport.position = position
        try renderer.update(state, revision: revision)
        let status = try engine.renderOffline(512, to: output)
        precondition(status == .success, "PCM rendering must not stall")
        for channel in 0..<2 { samples[channel] += Array(UnsafeBufferPointer(start: output.floatChannelData![channel], count: Int(output.frameLength))) }
        position += Double(output.frameLength) / outputFormat.sampleRate
    }
    renderer.stop()
    return samples
}
func frequency(_ samples: [Float], from: Double, to: Double) -> Double {
    let start = Int(from * outputFormat.sampleRate), end = Int(to * outputFormat.sampleRate)
    let crossings = (start+1..<end).filter { samples[$0-1] <= 0 && samples[$0] > 0 }.count
    return Double(crossings) / (to-from)
}
for rate in [0.75, 1.0, 1.5] {
    let pcm = try renderTempo(rate)
    for channel in 0..<2 {
        let expected = Double(channel == 0 ? 440 : 880)
        let measured = frequency(pcm[channel], from: 0.3, to: 1)
        precondition(abs(measured-expected) < 4, "Tempo preserves stereo pitch: \(rate), \(measured)")
        let last = pcm[channel].lastIndex(where: { abs($0) > 0.003 }) ?? 0
        let end = Double(last) / outputFormat.sampleRate
        precondition(abs(end - 3 / rate) < 0.13, "Audio duration follows tempo: \(rate), \(end)")
    }
}
let changedPCM = try renderTempo(1.5, change: true)
for channel in 0..<2 {
    let measured = frequency(changedPCM[channel], from: 1.3, to: 1.8)
    precondition(abs(measured - Double(channel == 0 ? 440 : 880)) < 4, "Live edit preserves pitch")
    let first = Int(0.8 * outputFormat.sampleRate), last = Int(1.5 * outputFormat.sampleRate), window = Int(outputFormat.sampleRate * 0.01)
    for start in stride(from: first, to: last-window, by: window) {
        let rms = sqrt(changedPCM[channel][start..<start+window].reduce(0.0) { $0 + Double($1*$1) } / Double(window))
        precondition(rms > 0.025, "Live tempo edit must not introduce a gap")
    }
    let maximumStep = (first+1..<last).map { abs(changedPCM[channel][$0]-changedPCM[channel][$0-1]) }.max() ?? 1
    precondition(maximumStep < 0.03, "Live tempo edit must not introduce a click: \(maximumStep)")
}
print("TEMPO_STEREO_PITCH_DURATION_LIVE_CONTINUITY_OK")

// Finalizing a take updates the project while an existing voice is sounding.
// Its player, stretch latency and effect history must remain uninterrupted.
let finishEngine = AVAudioEngine()
try finishEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
let finishRenderer = StemAudioPlayback(engine: finishEngine, realtime: false)
finishRenderer.open(directory: directory)
var finishState = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id, position: 2, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
try finishRenderer.update(finishState, revision: 1)
for _ in 0..<32 {
    let status = try finishEngine.renderOffline(512, to: output)
    precondition(status == .success)
}
var finishPCM: [Float] = []
for take in 0..<3 {
    finishState.project.songs[0].tracks[0].clips.append(AudioClip(id: UUID(), name: "Finished recording", startTime: 0, duration: 1, audioFile: AudioFile(path: "tone.wav")))
    try finishRenderer.update(finishState, revision: UInt64(take + 2))
    for _ in 0..<8 {
        let status = try finishEngine.renderOffline(512, to: output)
        precondition(status == .success)
        finishPCM += Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
precondition(finishPCM.allSatisfy { $0 > 0.09 && $0 < 0.11 }, "finalizing takes preserves the currently playing PCM without gaps or doubled audio")
precondition(zip(finishPCM,finishPCM.dropFirst()).allSatisfy { abs($0 - $1) < 0.005 }, "take insertion cannot introduce a click in live playback")
finishRenderer.stop()
print("RECORDING_FINALIZATION_PRESERVES_PLAYING_PCM_OK")

// Six hardware channels make stereo/mono routing observable, without hardware.
let routingEngine = AVAudioEngine()
let routingFormat = AVAudioFormat(standardFormatWithSampleRate: outputFormat.sampleRate, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 6)!)
try routingEngine.enableManualRenderingMode(.offline, format: routingFormat, maximumFrameCount: 512)
let routing = StemAudioPlayback(engine: routingEngine, realtime: false)
routing.open(directory: directory)
var routeProject = Project.empty(name: "Groups and sends")
var folder = Track(id: UUID(), name: "Folder", role: .keys); folder.volume = 0.5
var child = Track(id: UUID(), name: "Child", role: .keys); child.parentTrackID = folder.id
child.clips = [AudioClip(id: UUID(), name: "Audio", startTime: 0, duration: 10, audioFile: AudioFile(path: "tone.wav"))]
routeProject.songs[0].tracks = [folder, child]
var routingState = ShowSnapshot(project: routeProject, transport: TransportState(playing: true, songId: routeProject.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
let routingBuffer = AVAudioPCMBuffer(pcmFormat: routingFormat, frameCapacity: 512)!
var routeRevision: UInt64 = 1
func routePeaks() throws -> [Float] {
    routeRevision += 1
    try routing.update(routingState, revision: routeRevision)
    var levels = Array(repeating: Float(0), count: 6)
    for iteration in 0..<24 {
        let status = try routingEngine.renderOffline(512, to: routingBuffer)
        precondition(status == .success, "routing must render")
        if iteration >= 16 {
            for channel in 0..<6 { for frame in 0..<Int(routingBuffer.frameLength) { levels[channel] = max(levels[channel], abs(routingBuffer.floatChannelData![channel][frame])) } }
        }
    }
    return levels
}
func checkRoutes(_ expected: [Float], _ description: String) throws {
    let actual = try routePeaks()
    if !zip(actual, expected).allSatisfy({ abs($0-$1)<0.005 }) { FileHandle.standardError.write(Data("Mixer input \(routingEngine.mainMixerNode.inputFormat(forBus: 0)) output \(routingEngine.mainMixerNode.outputFormat(forBus: 0)) manual \(routingEngine.manualRenderingFormat)\n".utf8)) }
    precondition(zip(actual, expected).allSatisfy { abs($0-$1)<0.005 }, "\(description): \(actual)")
}
try checkRoutes([0.05,0.05,0,0,0,0], "child defaults through folder fader to Master")
routingState.project.songs[0].tracks[1].secondaryPatch = OutputPatch(firstChannel: 3, channelCount: 2)
try checkRoutes([0.05,0.05,0.1,0.1,0,0], "two independent sends: group and direct hardware")
routingState.project.songs[0].tracks[0].mute = true
try checkRoutes([0,0,0.1,0.1,0,0], "folder mute does not mute child's direct send")
routingState.project.songs[0].tracks[1].patch = .master
try checkRoutes([0.1,0.1,0.1,0.1,0,0], "child can bypass muted folder and go straight to Master")
routingState.project.masterSecondaryPatch = OutputPatch(firstChannel: 5, channelCount: 2)
try checkRoutes([0.1,0.1,0.1,0.1,0.1,0.1], "Master has two independent hardware destinations")
routingState.project.masterMute = true
try checkRoutes([0,0,0.1,0.1,0,0], "Master mute affects both Master sends, not the direct route")
routingState.project.songs[0].tracks[1].secondaryPatch = OutputPatch(firstChannel: 4, channelCount: 1)
try checkRoutes([0,0,0,0.1,0,0], "mono route reaches only its hardware channel")
routingState.project.songs[0].tracks[1].patch = OutputPatch.none
routingState.project.songs[0].tracks[1].secondaryPatch = OutputPatch.none
try checkRoutes([0,0,0,0,0,0], "None disconnects each send")
routing.stop()
print("GROUP_MASTER_TWO_SENDS_SIX_HARDWARE_CHANNELS_PCM_OK")
let loopEngine = AVAudioEngine()
try loopEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
let loopAudio = StemAudioPlayback(engine: loopEngine, realtime: false)
loopAudio.open(directory: directory)
var loopProject = project
loopProject.songs[0].tracks = [Track(id: UUID(), name: "Loop", role: .keys)]
loopProject.songs[0].tracks[0].clips = [AudioClip(id: UUID(), name: "Repeated", startTime: 0, duration: 8, audioFile: AudioFile(path: "tone.wav"), loopStart: 0, loopLength: 1)]
var loopState = ShowSnapshot(project: loopProject, transport: snapshot.transport)
loopState.transport.playing = true; loopState.transport.position = 0; loopState.transport.songId = loopProject.songs[0].id
loopState.transport.subPlay.playing = false
let loopBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512)!
var rendered = 0
for _ in 0..<Int(outputFormat.sampleRate * 7 / 512) {
    loopState.transport.position = Double(rendered) / outputFormat.sampleRate
    try loopAudio.update(loopState, revision: 1)
    let loopStatus = try loopEngine.renderOffline(512, to: loopBuffer)
    precondition(loopStatus == .success)
    if rendered > Int(outputFormat.sampleRate * 1.5) {
        let peak = (0..<Int(loopBuffer.frameLength)).map { abs(loopBuffer.floatChannelData![0][$0]) }.max() ?? 0
        precondition(peak > 0.02, "expanded item must play through repeated source boundaries")
    }
    rendered += 512
}
loopAudio.stop()
print("ITEM_LOOP_CONTINUES_BEYOND_SOURCE_WITHOUT_SILENT_GAPS_OK")
// Each item processes independently before its track and master. The second
// item begins without effects; inserting its first effect keeps existing PCM.
let itemFXEngine = AVAudioEngine()
try itemFXEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
let itemFXAudio = StemAudioPlayback(engine: itemFXEngine, realtime: false)
itemFXAudio.open(directory: directory)
var itemFXProject = Project.empty(name: "Item FX")
var itemFXTrack = Track(id: UUID(), name: "FX track", role: .keys)
var reduction = NativeFXSettings()
reduction.inserted = ["Compressor"]; reduction.compressorEnabled = true
reduction.threshold = 0; reduction.ratio = 1; reduction.makeup = -6
let effectedClipID = UUID(), untreatedClipID = UUID()
itemFXTrack.fx = reduction
itemFXTrack.clips = [
    AudioClip(id: effectedClipID, name: "Item FX", startTime: 0, duration: 8, audioFile: AudioFile(path: "tone.wav"), gain: 0.5, fx: reduction),
    AudioClip(id: untreatedClipID, name: "Untreated item", startTime: 0, duration: 8, audioFile: AudioFile(path: "tone.wav"), gain: 0.5)
]
itemFXProject.songs[0].tracks = [itemFXTrack]; itemFXProject.masterVolume = 0.5
var itemFXState = ShowSnapshot(project: itemFXProject, transport: TransportState(playing: true, songId: itemFXProject.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: true, position: 0)))
let itemFXBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512)!
func itemFXPeak() throws -> Float {
    var maximum: Float = 0
    for block in 0..<24 {
        let status = try itemFXEngine.renderOffline(512, to: itemFXBuffer)
        precondition(status == .success)
        if block > 15 {
            for sample in 0..<Int(itemFXBuffer.frameLength) { maximum = max(maximum, abs(itemFXBuffer.floatChannelData![0][sample])) }
        }
    }
    return maximum
}
try itemFXAudio.update(itemFXState, revision: 1)
let itemFXInitial = try itemFXPeak()
precondition(itemFXInitial > 0.035 && itemFXInitial < 0.040, "clip/track/master processing and independent SubPlay chains: \(itemFXInitial)")
let insertedNodes = itemFXEngine.attachedNodes.count
var bypassedItem = reduction; bypassedItem.compressorEnabled = false
itemFXAudio.previewClipFX(effectedClipID, settings: bypassedItem)
let bypassedPeak = try itemFXPeak()
precondition(bypassedPeak > 0.047 && bypassedPeak < 0.053, "item bypass affects only the selected clip and preserves track processing: \(bypassedPeak)")
precondition(itemFXEngine.attachedNodes.count == insertedNodes, "bypass must reuse existing chain and players")
itemFXAudio.observeEffect(effectedClipID, effect: "Compressor", active: true)
_ = try itemFXPeak()
precondition((itemFXAudio.effectPeaks(effectedClipID, effect: "Compressor").max() ?? 0) > 0, "bypassed compressor still meters when its editor is open")
itemFXAudio.observeEffect(effectedClipID, effect: "Compressor", active: false)
itemFXState.transport.subPlay.playing = false
itemFXState.project.songs[0].tracks[0].clips[0].fx = bypassedItem
try itemFXAudio.update(itemFXState, revision: 2)
let beforeDynamicInsert = itemFXEngine.attachedNodes.count
itemFXAudio.previewClipFX(untreatedClipID, settings: reduction)
precondition(itemFXEngine.attachedNodes.count == beforeDynamicInsert, "first item effect activates its prepared chain without graph mutation")
let afterDynamicInsert = itemFXEngine.attachedNodes.count
for step in 0..<100 {
    var draft = reduction; draft.threshold = -Double(step % 50)
    itemFXAudio.previewClipFX(untreatedClipID, settings: draft)
}
itemFXAudio.previewClipFX(untreatedClipID, settings: reduction)
precondition(itemFXEngine.attachedNodes.count == afterDynamicInsert, "knob previews must not rebuild source players or effect topology")
let liveItemFXPeak = try itemFXPeak()
precondition(liveItemFXPeak > 0.017 && liveItemFXPeak < 0.020, "live insertion retains both independent PCM streams: \(liveItemFXPeak)")
itemFXAudio.observeEffect(untreatedClipID, effect: "Compressor", active: true)
_ = try itemFXPeak()
precondition((itemFXAudio.effectPeaks(untreatedClipID, effect: "Compressor").max() ?? 0) > 0, "clip compressor editor reads its native processor meter")
itemFXState.project.songs[0].tracks[0].clips[1].fx = reduction
itemFXState.project.songs[0].tracks[0].clips[0].muted = true
try itemFXAudio.update(itemFXState, revision: 3)
itemFXAudio.previewItemGain(effectedClipID, gain: 2)
let mutedFXPeak = try itemFXPeak()
precondition(mutedFXPeak > 0.005 && mutedFXPeak < 0.008, "item mute and gain preserve independent sibling FX: \(mutedFXPeak)")
var clipDelay = NativeFXSettings(); clipDelay.inserted = ["Delay"]
clipDelay.delayEnabled = true; clipDelay.delayTime = 0.01; clipDelay.delayMix = 100; clipDelay.feedback = 0
itemFXAudio.previewClipFX(untreatedClipID, settings: clipDelay)
itemFXAudio.observeEffect(untreatedClipID, effect: "Delay", active: true)
_ = try itemFXPeak()
precondition(itemFXAudio.spectrumFrame(untreatedClipID, effect: "Delay") != nil, "clip delay editor receives its own spectrum frame")
itemFXAudio.stop()
precondition(itemFXEngine.attachedNodes.count == afterDynamicInsert, "Stop retains prepared players and effects for immediate replay")
try itemFXEngine.start()
let stoppedFXPeak = try itemFXPeak()
precondition(stoppedFXPeak < 0.00001, "pooled voices and their effect tails must remain silent after Stop: \(stoppedFXPeak)")
itemFXAudio.prepareForClosing()
precondition(itemFXEngine.attachedNodes.count < beforeDynamicInsert, "closing releases pooled item processors")
print("ITEM_FX_INDEPENDENT_CHAINS_GAIN_MUTE_SUBPLAY_LIVE_PREVIEW_METERS_AND_SPECTRUM_OK")

// Bypass the whole item without overwriting individual processor switches.
let allBypassEngine = AVAudioEngine()
try allBypassEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
let allBypassAudio = StemAudioPlayback(engine: allBypassEngine, realtime: false)
allBypassAudio.open(directory: directory)
var allBypassProject = Project.empty(name: "Whole item FX bypass")
var allBypassTrack = Track(id: UUID(), name: "Bypass item", role: .keys)
var itemProcessors = reduction
itemProcessors.inserted = ["EQ", "Compressor"]
itemProcessors.eqEnabled = true
var shelf = EQBand(frequency: 20000, type: "lowShelf"); shelf.gain = -6
itemProcessors.bands = [shelf]
let allBypassClipID = UUID()
allBypassTrack.clips = [AudioClip(id: allBypassClipID, name: "Item", startTime: 0, duration: 8, audioFile: AudioFile(path: "tone.wav"), gain: 0.5, fx: itemProcessors)]
allBypassProject.songs[0].tracks = [allBypassTrack]
var allBypassState = ShowSnapshot(project: allBypassProject, transport: TransportState(playing: true, songId: allBypassProject.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: true, position: 0)))
let allBypassBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512)!
func allBypassPeak() throws -> Float {
    var peak: Float = 0
    for block in 0..<24 {
        let status = try allBypassEngine.renderOffline(512, to: allBypassBuffer)
        precondition(status == .success)
        if block > 15 { for frame in 0..<Int(allBypassBuffer.frameLength) { peak = max(peak, abs(allBypassBuffer.floatChannelData![0][frame])) } }
    }
    return peak
}
try allBypassAudio.update(allBypassState, revision: 1)
let bothProcessorsPCM = try allBypassPeak()
precondition(bothProcessorsPCM > 0.023 && bothProcessorsPCM < 0.028, "EQ and Compressor initially process both heads: \(bothProcessorsPCM)")
let allBypassNodes = allBypassEngine.attachedNodes.count
precondition(allBypassAudio.eqSpectrumFrames(allBypassClipID).isEmpty, "closed item EQ has no PCM capture")
allBypassAudio.observeEffect(allBypassClipID, effect: "EQ", active: true)
allBypassAudio.observeEffect(allBypassTrack.id, effect: "EQ", active: true)
allBypassAudio.observeEffect(nil, effect: "EQ", active: true)
_ = try allBypassPeak()
let itemRTAFrames = allBypassAudio.eqSpectrumFrames(allBypassClipID)
precondition(itemRTAFrames.count == 2 && itemRTAFrames.allSatisfy { $0.input?.count == 4096 * MemoryLayout<Float>.size && $0.output?.count == $0.input?.count }, "item RTA receives independent main and SubPlay PCM")
precondition(allBypassAudio.eqSpectrumFrames(allBypassTrack.id).count == 1 && allBypassAudio.eqSpectrumFrames(nil).count == 1, "track and Master RTA receive their own native PCM")
precondition(allBypassEngine.attachedNodes.count == allBypassNodes, "opening RTA must not add audio taps, reconnect or replace any nodes")
allBypassAudio.observeEffect(allBypassClipID, effect: "EQ", active: false)
allBypassAudio.observeEffect(allBypassTrack.id, effect: "EQ", active: false)
allBypassAudio.observeEffect(nil, effect: "EQ", active: false)
_ = try allBypassPeak()
precondition(allBypassAudio.eqSpectrumFrames(allBypassClipID).isEmpty && allBypassAudio.eqSpectrumFrames(allBypassTrack.id).isEmpty && allBypassAudio.eqSpectrumFrames(nil).isEmpty, "closed item, track and Master EQs stop PCM capture while playback continues")
print("EQ_RTA_ITEM_BOTH_HEADS_TRACK_MASTER_AND_ZERO_GRAPH_RECONNECT_OK")
allBypassAudio.previewClipFXBypass(allBypassClipID, bypassed: true)
let wholeBypassPCM = try allBypassPeak()
precondition(wholeBypassPCM > 0.09 && wholeBypassPCM < 0.11, "whole item bypass returns dry PCM in both existing heads: \(wholeBypassPCM)")
precondition(allBypassEngine.attachedNodes.count == allBypassNodes, "whole item bypass cannot reconnect or replace players")
allBypassState.project.songs[0].tracks[0].clips[0].fxBypassed = true
try allBypassAudio.update(allBypassState, revision: 2)
let committedBypassPCM = try allBypassPeak()
precondition(committedBypassPCM > 0.09 && committedBypassPCM < 0.11, "committed bypass survives snapshot synchronization")
allBypassAudio.previewItemGain(allBypassClipID, gain: 0.25)
let bypassGainPCM = try allBypassPeak()
precondition(bypassGainPCM > 0.045 && bypassGainPCM < 0.055, "item gain remains independent of the whole FX bypass")
allBypassState.project.songs[0].tracks[0].clips[0].gain = 0.25
try allBypassAudio.update(allBypassState, revision: 3)
allBypassAudio.previewClipFXBypass(allBypassClipID, bypassed: false)
let processorsRestoredPCM = try allBypassPeak()
precondition(processorsRestoredPCM > 0.011 && processorsRestoredPCM < 0.014, "unbypass restores original EQ and Compressor parameters: \(processorsRestoredPCM)")
allBypassState.project.songs[0].tracks[0].clips[0].fxBypassed = false
try allBypassAudio.update(allBypassState, revision: 4)
precondition(allBypassState.project.songs[0].tracks[0].clips[0].fx == itemProcessors && itemProcessors.eqEnabled && itemProcessors.compressorEnabled, "whole bypass preserves individual processor switches and parameters")
precondition(allBypassEngine.attachedNodes.count == allBypassNodes, "bypass on/off leaves source and DSP topology unchanged")
allBypassAudio.stop()
print("ITEM_FX_WHOLE_CHAIN_BYPASS_PRESERVES_PROCESSORS_GAIN_HEADS_AND_TOPOLOGY_PCM_OK")

// Wet audio can arrive after the clip ends. Retain only its processing tail,
// then release all memory and nodes when transport is stopped.
let tailEngine = AVAudioEngine()
try tailEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
let tailAudio = StemAudioPlayback(engine: tailEngine, realtime: false)
tailAudio.open(directory: directory)
var tailProject = Project.empty(name: "Item tail")
var tailTrack = Track(id: UUID(), name: "Tail", role: .keys)
var delayedTail = clipDelay; delayedTail.delayTime = 0.3; delayedTail.feedback = 30
tailTrack.clips = [AudioClip(id: UUID(), name: "Short item", startTime: 0, duration: 0.2, audioFile: AudioFile(path: "tone.wav"), fx: delayedTail)]
tailProject.songs[0].tracks = [tailTrack]
var tailState = ShowSnapshot(project: tailProject, transport: TransportState(playing: true, songId: tailProject.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
let tailBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512)!
var tailMaximum: Float = 0
for block in 0..<Int(outputFormat.sampleRate * 0.45 / 512) {
    tailState.transport.position = Double(block * 512) / outputFormat.sampleRate
    try tailAudio.update(tailState, revision: 1)
    let renderedTail = try tailEngine.renderOffline(512, to: tailBuffer)
    precondition(renderedTail == .success)
    if tailState.transport.position > 0.32 {
        for sample in 0..<Int(tailBuffer.frameLength) { tailMaximum = max(tailMaximum, abs(tailBuffer.floatChannelData![0][sample])) }
    }
}
precondition(tailMaximum > 0.05, "delay tail keeps sounding after item boundary: \(tailMaximum)")
tailState.transport.playing = false
try tailAudio.update(tailState, revision: 1)
try tailEngine.start()
var stoppedTail: Float = 0
for _ in 0..<12 {
    let renderedTail = try tailEngine.renderOffline(512, to: tailBuffer)
    precondition(renderedTail == .success)
    for sample in 0..<Int(tailBuffer.frameLength) { stoppedTail = max(stoppedTail, abs(tailBuffer.floatChannelData![0][sample])) }
}
precondition(stoppedTail < 0.000001, "Stop clears per-item effect tails immediately: \(stoppedTail)")
tailAudio.stop()
print("ITEM_FX_NATURAL_TAIL_AND_STOP_CLEANUP_OK")

// Resized timecode items gate output independently of the original region,
// while the encoded clock keeps advancing from its original region origin.
let spanEngine = AVAudioEngine()
try spanEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
let spanAudio = StemAudioPlayback(engine: spanEngine, realtime: false)
spanAudio.open(directory: directory)
var spanProject = Project.empty(name: "Timecode item span")
let spanRegion = Part(id: UUID(), name: "Region", startTime: 1, endTime: 2)
spanProject.songs[0].parts = [spanRegion]
var spanTrack = Track(id: UUID(), name: "Timecode", role: TrackRole(rawValue: "timecode"))
var spanSettings = TimecodeSettings(); spanSettings.mode = "ltc"; spanSettings.offset = 10; spanSettings.regionRelative = true
spanTrack.timecode = spanSettings; spanTrack.patch = .stereo
spanTrack.clips = [AudioClip(id: Project.timecodeItemID(spanRegion.id), name: "LTC", startTime: 0.5, duration: 2, timecodeStartOffset: -0.5, timecodeEndOffset: 0.5)]
spanProject.songs[0].tracks = [spanTrack]
let beforeSpan = TimecodePlaybackSpan(song: spanProject.songs[0], track: spanTrack, position: 0.3, settings: spanSettings, preferredRegion: spanRegion.id)!
precondition(abs(beforeSpan.delay - 0.2) < 0.000001 && beforeSpan.time == 9.5 && beforeSpan.end == 11.5, "timecode lookahead uses resized bounds and original clock origin")
let leftSpan = TimecodePlaybackSpan(song: spanProject.songs[0], track: spanTrack, position: 0.75, settings: spanSettings, preferredRegion: spanRegion.id)!
let rightSpan = TimecodePlaybackSpan(song: spanProject.songs[0], track: spanTrack, position: 2.25, settings: spanSettings, preferredRegion: spanRegion.id)!
precondition(leftSpan.time == 9.75 && rightSpan.time == 11.25, "timecode advances monotonically through both extended edges without modulo")
precondition(TimecodePlaybackSpan(song: spanProject.songs[0], track: spanTrack, position: 2.6, settings: spanSettings, preferredRegion: spanRegion.id) == nil, "timecode item ends independently of its region")
var spanState = ShowSnapshot(project: spanProject, transport: TransportState(playing: true, songId: spanProject.songs[0].id, position: 0.3, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
let spanBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512)!
func timecodeSpanPeak(at position: Double, revision: UInt64) throws -> Float {
    spanState.transport.position = position
    try spanAudio.update(spanState, revision: revision)
    var peak: Float = 0
    for _ in 0..<4 {
        let status = try spanEngine.renderOffline(512, to: spanBuffer)
        precondition(status == .success)
        for sample in 0..<Int(spanBuffer.frameLength) { peak = max(peak, abs(spanBuffer.floatChannelData![0][sample])) }
    }
    return peak
}
let preSpanPCM = try timecodeSpanPeak(at: 0.3, revision: 1)
precondition(preSpanPCM < 0.000001, "positive timecode offset must not emit before scheduled item start: \(preSpanPCM)")
let leftSpanPCM = try timecodeSpanPeak(at: 0.75, revision: 1)
precondition(leftSpanPCM > 0.2, "extended left timecode span emits LTC before original region starts: \(leftSpanPCM)")
let timecodeMeter = spanAudio.meter(for: spanTrack.id)
Thread.sleep(forTimeInterval: 0.04)
try spanAudio.update(spanState, revision: 1)
precondition(timecodeMeter.levels.x > 0.2 && timecodeMeter.levels.y > 0.2, "Timecode track meter reads real stereo LTC independently of Master")
let rightSpanPCM = try timecodeSpanPeak(at: 2.25, revision: 1)
precondition(rightSpanPCM > 0.2, "extended right timecode span emits LTC after original region ends: \(rightSpanPCM)")
let afterSpanPCM = try timecodeSpanPeak(at: 2.6, revision: 1)
precondition(afterSpanPCM < 0.000001, "LTC stops at resized item end: \(afterSpanPCM)")
spanState.project.songs[0].tracks[0].clips[0].startTime = 1.2
spanState.project.songs[0].tracks[0].clips[0].duration = 0.6
let trimmedBeforePCM = try timecodeSpanPeak(at: 0.75, revision: 2)
precondition(trimmedBeforePCM < 0.000001, "trimmed timecode span remains silent before its new start")
let trimmedInsidePCM = try timecodeSpanPeak(at: 1.3, revision: 2)
precondition(trimmedInsidePCM > 0.2, "trimmed item emits within its independent timecode span")
spanState.project.songs[0].tracks[0].timecode?.mode = "mtc"
_ = try timecodeSpanPeak(at: 1.3, revision: 3)
precondition(timecodeMeter.levels.x == 0 && timecodeMeter.levels.y == 0, "MTC immediately clears the LTC audio meter")
spanState.project.songs[0].tracks[0].timecode?.mode = "ltc"
_ = try timecodeSpanPeak(at: 1.3, revision: 4)
spanState.project.songs[0].tracks = []
let deletedTimecodePeak = try timecodeSpanPeak(at: 1.3, revision: 5)
precondition(deletedTimecodePeak < 0.000001, "deleting the Timecode track must stop the still-running LTC generator")
spanAudio.stop()
print("TIMECODE_ITEM_SPAN_EDGES_MONOTONIC_CLOCK_AND_FUTURE_START_GATING_PCM_OK")

// Left extension starts at the source tail, runs forward to the front, then
// repeats forward. Right extension continues from the front of the same source.
do {
    let file = try AVAudioFile(forWriting: directory.appendingPathComponent("wrap.wav"), settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200)!
    buffer.frameLength = 88200
    for channel in 0..<2 {
        for frame in 0..<88200 { buffer.floatChannelData![channel][frame] = Float(frame / 22050 + 1) / 10 }
    }
    try file.write(from: buffer)
}
let wrapEngine = AVAudioEngine()
try wrapEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
let wrapAudio = StemAudioPlayback(engine: wrapEngine, realtime: false)
wrapAudio.open(directory: directory)
var wrapProject = Project.empty(name: "Extended source phase")
var wrapTrack = Track(id: UUID(), name: "Wrap", role: .keys)
wrapTrack.clips = [AudioClip(id: UUID(), name: "Extended", startTime: 1.5, duration: 3, sourceOffset: 1.5, audioFile: AudioFile(path: "wrap.wav"), loopStart: 0, loopLength: 2)]
wrapProject.songs[0].tracks = [wrapTrack]
let wrapState = ShowSnapshot(project: wrapProject, transport: TransportState(playing: true, songId: wrapProject.songs[0].id, position: 1.5, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
try wrapAudio.update(wrapState, revision: 1)
let wrapBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512)!
let expectedPhases: [Float] = [0.4,0.1,0.2,0.3,0.4,0.1]
var checkedPhases: Set<Int> = []
for block in 0..<Int(outputFormat.sampleRate * 2.9 / 512) {
    let status = try wrapEngine.renderOffline(512, to: wrapBuffer)
    precondition(status == .success)
    let time = Double(block * 512) / outputFormat.sampleRate
    let phase = Int(time / 0.5)
    let within = time - Double(phase) * 0.5
    if expectedPhases.indices.contains(phase) && within > 0.2 && within < 0.3 {
        let peak = (0..<Int(wrapBuffer.frameLength)).map { abs(wrapBuffer.floatChannelData![0][$0]) }.max() ?? 0
        precondition(abs(peak - expectedPhases[phase]) < 0.01, "item extension must play forward tail→front and front→tail: phase \(phase), actual \(peak)")
        checkedPhases.insert(phase)
    }
}
precondition(checkedPhases.count == expectedPhases.count, "verify source phase on both item extensions")
wrapAudio.stop()
print("ITEM_LEFT_AND_RIGHT_EXTENSION_FORWARD_PHASE_PCM_OK")

// Scalar mixer edits must preserve scheduled main/SubPlay voices and the graph.
let scalarEngine = AVAudioEngine()
try scalarEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
let scalarAudio = StemAudioPlayback(engine: scalarEngine, realtime: false)
scalarAudio.open(directory: directory)
var scalarProject = Project.empty(name: "Incremental mixer PCM")
var group = Track(id: UUID(), name: "Group", role: .keys); group.volume = 0.5
func scalarTrack(_ name: String, volume: Double, parent: UUID? = nil, onset: Double = 0) -> Track {
    var track = Track(id: UUID(), name: name, role: .keys)
    track.volume = volume; track.parentTrackID = parent
    track.clips = [AudioClip(id: UUID(), name: name, startTime: onset, duration: 10, audioFile: AudioFile(path: "tone.wav"))]
    return track
}
let childA = scalarTrack("Child A", volume: 1, parent: group.id)
let childB = scalarTrack("Child B", volume: 0.5, parent: group.id)
let outsider = scalarTrack("Outside", volume: 0.25)
scalarProject.songs[0].tracks = [group, childA, childB, outsider]
let scalarState = ShowSnapshot(project: scalarProject, transport: TransportState(playing: true, songId: scalarProject.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: true, position: 0)))
try scalarAudio.update(scalarState, revision: 1)
let scalarNodes = scalarEngine.attachedNodes
let scalarBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512)!
func scalarCheck(_ expected: Float, _ message: String) throws {
    var peak: Float = 0
    for block in 0..<16 {
        let status = try scalarEngine.renderOffline(512, to: scalarBuffer)
        precondition(status == .success, "incremental mixer must keep rendering")
        if block >= 10 {
            for frame in 0..<Int(scalarBuffer.frameLength) { peak = max(peak, abs(scalarBuffer.floatChannelData![0][frame])) }
        }
    }
    precondition(abs(peak - expected) < 0.003, "\(message): expected \(expected), PCM \(peak)")
    precondition(scalarEngine.attachedNodes == scalarNodes && scalarEngine.isRunning, "scalar edits must preserve every scheduled node")
}
try scalarCheck(0.2, "both heads route through group/master")
scalarAudio.previewMute(childA.id, muted: true); try scalarCheck(0.1, "track mute affects both heads only on that track")
scalarAudio.previewMute(childA.id, muted: false); try scalarCheck(0.2, "track unmute resumes existing PCM")
scalarAudio.previewSolo(childA.id, solo: true); try scalarCheck(0.1, "child solo keeps its group bus audible")
scalarAudio.previewSolo(childA.id, solo: false); try scalarCheck(0.2, "clearing solo restores other ongoing tracks")
scalarAudio.previewSolo(group.id, solo: true); try scalarCheck(0.15, "group solo admits children and excludes outsiders")
scalarAudio.previewMute(group.id, muted: true); try scalarCheck(0, "muting the solo group gates children")
scalarAudio.previewMute(group.id, muted: false); try scalarCheck(0.15, "group mute preserves solo eligibility")
scalarAudio.previewSolo(group.id, solo: false)
scalarAudio.previewItemGain(childA.clips[0].id, gain: 0.5); try scalarCheck(0.15, "item gain remains independent on both heads")
scalarAudio.previewClipMute(childA.clips[0].id, muted: true); try scalarCheck(0.1, "clip mute gates primary and SubPlay voices")
scalarAudio.previewClipMute(childA.clips[0].id, muted: false); try scalarCheck(0.15, "clip unmute retains its edited gain")
scalarAudio.previewMute(nil, muted: true); try scalarCheck(0, "master mute gates its sends")
scalarAudio.previewPatch(childA.id, patch: .stereo, slot: 0); try scalarCheck(0.1, "live direct routing bypasses muted master")
scalarAudio.previewPatch(childA.id, patch: .master, slot: 1); try scalarCheck(0.1, "second send preserves direct output")
scalarAudio.previewMute(nil, muted: false); try scalarCheck(0.3, "both sends coexist without rescheduling players")
scalarAudio.previewPatch(childA.id, patch: .stereo, slot: 1); try scalarCheck(0.2, "duplicate hardware output is not doubled")
scalarAudio.previewPatch(childA.id, patch: .none, slot: 1)
scalarAudio.previewPatch(childA.id, patch: .masterGroup, slot: 0); try scalarCheck(0.15, "switching back to group restores parent gain")
scalarAudio.previewPatch(nil, patch: .none, slot: 0); try scalarCheck(0, "master output can be disabled independently")
scalarAudio.previewPatch(nil, patch: .stereo, slot: 1); try scalarCheck(0.15, "master second output carries existing mix")
scalarAudio.previewPatch(nil, patch: .stereo, slot: 0); try scalarCheck(0.15, "duplicate master outputs are not doubled")
scalarAudio.previewPatch(nil, patch: .none, slot: 1)
scalarAudio.previewVolume(group.id, gain: 0.25); try scalarCheck(0.1, "scalar group fader preserves all voices")
scalarAudio.previewVolume(nil, gain: 0.5); try scalarCheck(0.05, "scalar master fader preserves all voices")
scalarAudio.previewMute(UUID(), muted: true); scalarAudio.previewSolo(UUID(), solo: true)
scalarAudio.previewPatch(childA.id, patch: .stereo, slot: 2)
scalarAudio.previewPatch(nil, patch: .master, slot: 0)
try scalarCheck(0.05, "invalid scalar targets/slots remain atomic")
scalarAudio.previewPatches(childA.id, patches: [.none, .none, .master])
try scalarCheck(0.0875, "third output instance sends audio through master")
scalarAudio.previewPatches(childA.id, patches: [.master, .master, .master, .master])
try scalarCheck(0.0875, "duplicate master destinations do not double audio")
scalarAudio.previewPatches(childA.id, patches: [])
try scalarCheck(0.0375, "removing every output silences only that track")
scalarAudio.previewPatches(nil, patches: [.none, .none, .stereo, .stereo])
try scalarCheck(0.0375, "third master output works and duplicate hardware sends are deduplicated")
scalarAudio.previewRouting([childA.id: TrackRouting(receives: [], transmitters: [group.id, childB.id, outsider.id, outsider.id]), outsider.id: TrackRouting(receives: [nil, nil, childA.id], transmitters: [])])
try scalarCheck(0.06875, "more than two internal sends carry audio and reciprocal receives are deduplicated")
scalarAudio.previewRouting([childA.id: TrackRouting(), outsider.id: TrackRouting()])
try scalarCheck(0.0375, "removing internal sends and receives restores existing playback without recreating nodes")
scalarAudio.previewPatches(nil, patches: [])
try scalarCheck(0, "removing every master output silences hardware")
scalarAudio.stop()
// One hardware matrix carries arbitrary output instances without growing the graph.
let routeEngine = AVAudioEngine()
let routeLayout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 8)!
let routeFormat = AVAudioFormat(standardFormatWithSampleRate: outputFormat.sampleRate, channelLayout: routeLayout)
try routeEngine.enableManualRenderingMode(.offline, format: routeFormat, maximumFrameCount: 512)
let routeSource = AVAudioSourceNode { silent, _, frames, list in
    silent.pointee = false
    for (channel, buffer) in UnsafeMutableAudioBufferListPointer(list).enumerated() {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        for frame in 0..<Int(frames) { data[frame] = channel == 0 ? 0.2 : 0.6 }
    }
    return noErr
}
let matrix = JarasChannelRouter.makeNode()
routeEngine.attach(routeSource); routeEngine.attach(matrix)
routeEngine.connect(routeSource, to: matrix, format: outputFormat)
routeEngine.connect(matrix, to: routeEngine.mainMixerNode, format: routeFormat)
routeEngine.connect(routeEngine.mainMixerNode, to: routeEngine.outputNode, format: routeFormat)
JarasChannelRouter.configurePatches(matrix, firsts: [1,3,5,3], counts: [2,2,1,2])
routeEngine.prepare(); try routeEngine.start()
let routeBuffer = AVAudioPCMBuffer(pcmFormat: routeFormat, frameCapacity: 512)!
for _ in 0..<16 { let status = try routeEngine.renderOffline(512, to: routeBuffer); precondition(status == .success) }
for (channel, expected) in [Float(0.2),0.6,0.2,0.6,0.4,0,0,0].enumerated() {
    precondition(abs(routeBuffer.floatChannelData![channel][400] - expected) < 0.001, "arbitrary hardware outputs preserve stereo, downmix mono and suppress duplicate destinations")
}
JarasChannelRouter.configurePatches(matrix, firsts: [], counts: [])
for _ in 0..<16 { let status = try routeEngine.renderOffline(512, to: routeBuffer); precondition(status == .success) }
for channel in 0..<8 { precondition(abs(routeBuffer.floatChannelData![channel][400]) < 0.0001) }
routeEngine.stop()
print("DYNAMIC_HARDWARE_STEREO_MONO_DUPLICATE_SUPPRESSION_AND_REMOVAL_PCM_OK")
print("INCREMENTAL_MUTE_SOLO_CLIP_MUTE_GROUP_DUAL_PATCH_AND_FADERS_PCM_TOPOLOGY_OK")

// Preview before onset must reach the clip index used to schedule future voices.
scalarAudio.open(directory: directory)
var futureProject = Project.empty(name: "Future clip scalar cache")
let futureTrack = scalarTrack("Future", volume: 1, onset: 2)
futureProject.songs[0].tracks = [futureTrack]
var futureState = ShowSnapshot(project: futureProject, transport: TransportState(playing: true, songId: futureProject.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: true, position: 0)))
try scalarAudio.update(futureState, revision: 1)
scalarAudio.previewItemGain(futureTrack.clips[0].id, gain: 0.25)
scalarAudio.previewClipMute(futureTrack.clips[0].id, muted: true)
futureState.project.songs[0].tracks[0].clips[0].gain = 0.25
futureState.project.songs[0].tracks[0].clips[0].muted = true
futureState.transport.position = 2; futureState.transport.subPlay.position = 2
try scalarAudio.update(futureState, revision: 1)
func futurePeak() throws -> Float {
    var result: Float = 0
    for block in 0..<16 {
        let status = try scalarEngine.renderOffline(512, to: scalarBuffer)
        precondition(status == .success)
        if block >= 10 { for frame in 0..<Int(scalarBuffer.frameLength) { result = max(result, abs(scalarBuffer.floatChannelData![0][frame])) } }
    }
    return result
}
let futureMuted = try futurePeak()
precondition(futureMuted < 0.000001, "future muted onset must use scalar clip cache on both heads")
scalarAudio.previewClipMute(futureTrack.clips[0].id, muted: false)
let futureUnmuted = try futurePeak()
precondition(abs(futureUnmuted - 0.05) < 0.003, "future onset retains preview gain when unmuted: \(futureUnmuted)")
scalarAudio.stop()
print("INCREMENTAL_CLIP_MUTE_AND_GAIN_BEFORE_FUTURE_ONSET_PCM_OK")

// Prepare-only queues never pre-schedule the incoming PCM across the boundary.
scalarAudio.open(directory: directory)
var readyAudioProject = Project.empty(name: "Prepare queued song")
let readyIncoming = scalarTrack("Queued", volume: 1, onset: 2)
let readyCurrentID = UUID(), readyIncomingID = UUID()
readyAudioProject.songs[0].tracks = [readyIncoming]
readyAudioProject.songs[0].parts = [Part(id: readyCurrentID, name: "Current", startTime: 0, endTime: 2), Part(id: readyIncomingID, name: "Queued", startTime: 2, endTime: 10)]
readyAudioProject.regionSetlist = RegionSetlist(prepareWithoutPlayback: true)
var readyAudioState = ShowSnapshot(project: readyAudioProject, transport: TransportState(playing: true, songId: readyAudioProject.songs[0].id, position: 1.8, regionId: readyCurrentID, queuedRegionId: readyIncomingID, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 2)))
try scalarAudio.update(readyAudioState, revision: 1)
let readySilence = try futurePeak()
precondition(readySilence < 0.000001, "prepare-only mode must not schedule queued audio before Stop")
readyAudioState.transport.playing = false; readyAudioState.transport.regionId = readyIncomingID; readyAudioState.transport.queuedRegionId = nil; readyAudioState.transport.position = 2; readyAudioState.transport.editPosition = 2
try scalarAudio.update(readyAudioState, revision: 1)
readyAudioState.transport.playing = true
try scalarAudio.update(readyAudioState, revision: 1)
let readyPlayed = try futurePeak()
precondition(abs(readyPlayed - 0.1) < 0.003, "prepared song begins sounding when Play is explicitly pressed")
scalarAudio.stop()
print("PREPARE_ONLY_QUEUE_SILENCE_AND_EXPLICIT_PLAY_PCM_OK")

// Overlapping songs in one drawer must not leak the previous song's PCM.
scalarAudio.open(directory: directory)
var drawerProject = Project.empty(name: "Unified song ownership")
let previousSong = scalarTrack("Previous song", volume: 0.5)
let incomingSong = scalarTrack("Incoming song", volume: 1, onset: 2)
drawerProject.songs[0].tracks = [previousSong, incomingSong]
let parentID = UUID(), previousID = UUID(), incomingID = UUID()
drawerProject.songs[0].parts = [
    Part(id: parentID, name: "Unified", startTime: 0, endTime: 12),
    Part(id: previousID, name: "Previous", startTime: 0, endTime: 10, parentRegionID: parentID),
    Part(id: incomingID, name: "Incoming", startTime: 2, endTime: 12, parentRegionID: parentID)
]
var drawerState = ShowSnapshot(project: drawerProject, transport: TransportState(playing: true, songId: drawerProject.songs[0].id, position: 3, regionId: incomingID, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
try scalarAudio.update(drawerState, revision: 1)
let isolatedChild = try futurePeak()
precondition(abs(isolatedChild - 0.1) < 0.003, "starting drawer child ignores previous overlapping audio: \(isolatedChild)")
drawerState.transport.regionId = parentID
try scalarAudio.update(drawerState, revision: 1)
let wholeGroup = try futurePeak()
precondition(abs(wholeGroup - 0.15) < 0.003, "parent keeps all original overlapping audio: \(wholeGroup)")
drawerState.transport.regionId = incomingID
try scalarAudio.update(drawerState, revision: 1)
let filteredRunning = try futurePeak()
precondition(abs(filteredRunning - 0.1) < 0.003, "ownership filters already scheduled previous voices: \(filteredRunning)")
// Cancelled future-song muting: flow after the starting child remains intact.
drawerState.transport.regionId = previousID; drawerState.transport.queuedRegionId = UUID()
try scalarAudio.update(drawerState, revision: 1)
let laterDrawerAudio = try futurePeak()
precondition(abs(laterDrawerAudio - 0.15) < 0.003, "queueing another song must not mute later drawer stems before the parent ends: \(laterDrawerAudio)")
scalarAudio.stop(); scalarAudio.open(directory: directory)
drawerState.transport.regionId = previousID; drawerState.transport.position = 0
// Queueing alone must not touch the current main head.
drawerState.transport.queuedRegionId = incomingID
try scalarAudio.update(drawerState, revision: 1)
let queuedOnly = try futurePeak()
precondition(abs(queuedOnly - 0.05) < 0.003, "queueing leaves main song's audio intact: \(queuedOnly)")
drawerState.transport.subPlay = SubPlayState(playing: true, position: 3)
try scalarAudio.update(drawerState, revision: 1)
let isolatedSub = try futurePeak()
precondition(abs(isolatedSub - 0.15) < 0.003, "SubPlay excludes the previous audio at its own position: \(isolatedSub)")
drawerState.transport.subPlayPromotion = 1; drawerState.transport.subPlay.playing = false
// Match the core's handoff position and ID; retain the incoming player.
drawerState.transport.position = 3; drawerState.transport.regionId = incomingID; drawerState.transport.queuedRegionId = nil
try scalarAudio.update(drawerState, revision: 1)
let isolatedPromoted = try futurePeak()
precondition(abs(isolatedPromoted - 0.1) < 0.003, "promotion preserves incoming PCM without previous song: \(isolatedPromoted)")
scalarAudio.stop()
print("UNIFIED_DRAWER_MAIN_SUBPLAY_OWNERSHIP_AND_PROMOTION_PCM_OK")

try scalarAudio.update(drawerState, revision: 1)
precondition(scalarEngine.isRunning)
scalarAudio.prepareForClosing()
precondition(!scalarEngine.isRunning, "closing releases the audio device")
drawerState.transport.playing = false
try scalarAudio.update(drawerState, revision: 1)
precondition(!scalarEngine.isRunning, "cleanup's stopped transport must not wake the device again")
scalarAudio.open(directory: directory)
drawerState.transport.playing = true
try scalarAudio.update(drawerState, revision: 2)
let reopenedPeak = try futurePeak()
precondition(abs(reopenedPeak - 0.1) < 0.003, "reopening after resource release restores streamed PCM")
scalarAudio.prepareForClosing()
print("CLOSING_RELEASES_DEVICE_AND_FILES_AND_REOPEN_RESTORES_PCM_OK")

let directEngine = AVAudioEngine()
try directEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
let directAudio = StemAudioPlayback(engine: directEngine, realtime: false)
directAudio.open(directory: directory)
var directProject = Project.empty(name: "Direct routes")
var sender = Track(id: UUID(), name: "Send", role: .other)
var receiver = Track(id: UUID(), name: "Receive", role: .other); receiver.volume = 0.5
sender.patch = OutputPatch.none
sender.clips = [AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 10, audioFile: AudioFile(path: "tone.wav"))]
sender.routing = TrackRouting(transmitters: [receiver.id, nil]); receiver.routing = TrackRouting(receives: [sender.id, nil])
directProject.songs[0].tracks = [sender, receiver]
let directState = ShowSnapshot(project: directProject, transport: TransportState(playing: true, songId: directProject.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
try directAudio.update(directState, revision: 1)
let directBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512)!
var directStep = 0
func directCheck(_ expected: Float) throws {
    directStep += 1
    var result: Float = 0
    for iteration in 0..<24 {
        let status = try directEngine.renderOffline(512, to: directBuffer)
        if status == .success && iteration > 15 { for i in 0..<Int(directBuffer.frameLength) { result = max(result, abs(directBuffer.floatChannelData![0][i])) } }
    }
    precondition(abs(result - expected) < 0.003, "direct route step \(directStep), PCM: \(result) vs \(expected)")
}
try directCheck(0.05)
directAudio.previewRouting([sender.id: TrackRouting()]); try directCheck(0.05)
directAudio.previewRouting([receiver.id: TrackRouting()]); try directCheck(0)
directAudio.previewRouting([sender.id: TrackRouting(transmitters: [receiver.id, nil])]); try directCheck(0.05)
directAudio.prepareForClosing()
print("LIVE_RECEIVE_TRANSMITTER_DEDUPLICATION_AND_INCREMENTAL_REMOVAL_PCM_OK")

let orderedEngine = AVAudioEngine()
try orderedEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
let orderedAudio = StemAudioPlayback(engine: orderedEngine, realtime: false)
orderedAudio.open(directory: directory)
var orderedProject = Project.empty(name: "Reordered live tracks")
var orderedTrack = Track(id: UUID(), name: "Continuous players", role: .other)
orderedTrack.clips = [AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 10, audioFile: AudioFile(path: "tone.wav"))]
var orderedFX = NativeFXSettings(); orderedFX.inserted = ["EQ", "Compressor", "Delay", "Reverb"]
orderedTrack.fx = orderedFX; orderedProject.songs[0].tracks = [orderedTrack]
let orderedState = ShowSnapshot(project: orderedProject, transport: TransportState(playing: true, songId: orderedProject.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: true, position: 0)))
try orderedAudio.update(orderedState, revision: 1)
let orderedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512)!
func checkOrderedPlayers() throws {
    for _ in 0..<32 {
        let status = try orderedEngine.renderOffline(512, to: orderedBuffer)
        precondition(status == .success)
    }
    let sample = orderedBuffer.floatChannelData![0][128]
    precondition(abs(sample - 0.2) < 0.003, "reordering track/master processors must preserve both scheduled PCM streams: \(sample), \(orderedFX.inserted)")
}
try checkOrderedPlayers()
let orderedNodes = orderedEngine.attachedNodes.count
for keys in [["Reverb", "Delay", "EQ", "Compressor"], ["Compressor", "EQ", "Reverb", "Delay"], ["EQ", "Compressor", "Delay", "Reverb"]] {
    orderedFX.inserted = keys
    orderedAudio.previewFX(orderedTrack.id, settings: orderedFX)
    orderedAudio.previewFX(nil, settings: orderedFX)
    try checkOrderedPlayers()
    precondition(orderedEngine.attachedNodes.count == orderedNodes)
}
orderedAudio.prepareForClosing()
print("TRACK_MASTER_FX_REORDER_PRESERVES_MAIN_SUBPLAY_SCHEDULED_PCM_OK")


// Native Pitch and per-region transposition change frequency, not duration.
let sineFrames = 44100 * 30
let sine = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sineFrames))!
sine.frameLength = AVAudioFrameCount(sineFrames)
for c in 0..<2 { for i in 0..<sineFrames { sine.floatChannelData![c][i] = Float(0.1 * sin(2 * .pi * 440 * Double(i) / 44100)) } }
try AVAudioFile(forWriting: directory.appendingPathComponent("sine.wav"), settings: format.settings).write(from: sine)
let pitchEngine = AVAudioEngine()
try pitchEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
let pitchAudio = StemAudioPlayback(engine: pitchEngine, realtime: false); pitchAudio.open(directory: directory)
var pitchProject = Project.empty(name: "Semitones")
var pitchTrack = Track(id: UUID(), name: "Piano", role: .keys)
pitchTrack.clips = [AudioClip(id: UUID(), name: "Sine", startTime: 0, duration: 30, audioFile: AudioFile(path: "sine.wav"))]
let pitchRegion = Part(id: UUID(), name: "Song", startTime: 0, endTime: 30)
pitchProject.songs[0].tracks = [pitchTrack]; pitchProject.songs[0].parts = [pitchRegion]
var pitchState = ShowSnapshot(project: pitchProject, transport: TransportState(playing: true, songId: pitchProject.songs[0].id, position: 0, regionId: pitchRegion.id, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
try pitchAudio.update(pitchState, revision: 1)
let pitchBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512)!
func frequency() throws -> Double {
    var crossings = 0, samples = 0; var previous: Float = 0
    for iteration in 0..<96 {
        guard try pitchEngine.renderOffline(512, to: pitchBuffer) == .success else { continue }
        if iteration < 32 { continue }
        for i in 0..<Int(pitchBuffer.frameLength) {
            let sample = pitchBuffer.floatChannelData![0][i]
            if previous < 0 && sample >= 0 { crossings += 1 }; previous = sample; samples += 1
        }
    }
    return Double(crossings) * outputFormat.sampleRate / Double(samples)
}
func expectFrequency(_ value: Double) throws {
    let measured = try frequency()
    precondition(abs(measured - value) < 5, "pitch PCM frequency \(measured), expected \(value)")
}
try expectFrequency(440)
let noPitchNodes = pitchEngine.attachedNodes.count
var nativePitch = NativeFXSettings(); nativePitch.inserted = ["Pitch"]; nativePitch.pitchEnabled = true; nativePitch.pitchSemitones = 12
pitchAudio.previewFX(pitchTrack.id, settings: nativePitch)
precondition(pitchEngine.attachedNodes.count == noPitchNodes + 1, "Pitch allocates a processor only when inserted")
try expectFrequency(880)
nativePitch.pitchSemitones = -12; pitchAudio.previewFX(pitchTrack.id, settings: nativePitch); try expectFrequency(220)
nativePitch.pitchEnabled = false; pitchAudio.previewFX(pitchTrack.id, settings: nativePitch); try expectFrequency(440)
pitchState.project.songs[0].parts[0].pitchSemitones = 6
pitchState.project.songs[0].parts[0].pitchTrackIDs = [pitchTrack.id]
pitchState.project.songs[0].tracks[0].fx = nativePitch
try pitchAudio.update(pitchState, revision: 2); try expectFrequency(440 * pow(2, 0.5))
pitchState.project.songs[0].parts[0].pitchTrackIDs = []
try pitchAudio.update(pitchState, revision: 2); try expectFrequency(440)
precondition(pitchState.project.songs[0].tracks[0].clips[0].duration == 30, "transposition preserves timing")
let warmedNodes = pitchEngine.attachedNodes.count
pitchState.transport.playing = false; try pitchAudio.update(pitchState, revision: 2)
try pitchEngine.start()
for _ in 0..<24 { _ = try pitchEngine.renderOffline(512, to: pitchBuffer) }
precondition(Array(UnsafeBufferPointer(start: pitchBuffer.floatChannelData![0], count: Int(pitchBuffer.frameLength))).allSatisfy { abs($0) < 0.00001 }, "pooled sources are silent while stopped")
pitchState.transport.playing = true; try pitchAudio.update(pitchState, revision: 2)
precondition(pitchEngine.attachedNodes.count == warmedNodes, "repeated Play reuses the prepared sources")
try expectFrequency(440)
pitchAudio.prepareForClosing()
print("NATIVE_PITCH_REGION_TARGETS_LAZY_ALLOCATION_AND_TRANSPORT_REUSE_PCM_OK")

// Ignore Next also cancels a future source already scheduled in the lookahead.
let ignoreEngine = AVAudioEngine()
try ignoreEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
let ignoreAudio = StemAudioPlayback(engine: ignoreEngine, realtime: false); ignoreAudio.open(directory: directory)
var ignoreProject = Project.empty(name: "Ignore overlapping next song")
var ignoreTrack = Track(id: UUID(), name: "Stems", role: .other)
ignoreTrack.clips = [AudioClip(id: UUID(), name: "Current tail", startTime: 0, duration: 10, audioFile: AudioFile(path: "tone.wav")), AudioClip(id: UUID(), name: "Next", startTime: 0.3, duration: 9, audioFile: AudioFile(path: "tone.wav"))]
ignoreProject.songs[0].tracks = [ignoreTrack]
var ignoreState = ShowSnapshot(project: ignoreProject, transport: TransportState(playing: true, songId: ignoreProject.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
try ignoreAudio.update(ignoreState, revision: 1)
ignoreState.transport.ignoreNextAfter = 0.3; ignoreState.transport.ignoreNextEnd = 10
try ignoreAudio.update(ignoreState, revision: 1)
let ignoreBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512)!
for _ in 0..<48 { _ = try ignoreEngine.renderOffline(512, to: ignoreBuffer) }
precondition(abs(ignoreBuffer.floatChannelData![0][128] - 0.1) < 0.003, "Ignore Next keeps the current tail and cancels the next source")
ignoreAudio.prepareForClosing()
print("IGNORE_NEXT_PRESCHEDULED_SOURCE_MASK_PCM_OK")

print("REAL_AUDIO_RENDER_OK main=\(mainPeak) +12dB=\(louder) muted=\(muted)")

}
try MainActor.assumeIsolated { try run() }
