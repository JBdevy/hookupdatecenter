import Foundation
import AVFoundation
import Darwin
setbuf(stdout, nil)
@MainActor func run() throws {
    guard let path = ProcessInfo.processInfo.environment["JARAS_TEST_VST3"] else { fatalError("Set JARAS_TEST_VST3 to GainFixture.vst3") }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    var scanError: NSError?
    let descriptor = JarasVST3.scan(path, error: &scanError)[0]
    let classID = descriptor["classID"] as! String
    func plugin(_ instrument: Bool = false) -> ExternalPlugin { ExternalPlugin(classID: classID, name: "Fixture", path: path, category: instrument ? "Instrument|Synth" : "Fx") }
    func chain(_ plugins: [ExternalPlugin]) -> NativeFXSettings {
        var fx = NativeFXSettings(); fx.externalPlugins = plugins; fx.inserted = plugins.map(\.effectKey); return fx
    }
    let takeInstrument = plugin(true), takeEffect = plugin()
    var clip = AudioClip(id: UUID(), name: "Take synth", startTime: 0, duration: 3,
                         gain: 0.4, pan: -1, fx: chain([takeInstrument, takeEffect]),
                         midi: MIDIItem(notes: [MIDINote(start: 0, length: 6, pitch: 60, velocity: 100)], sourceBPM: 120))
    var project = Project.empty(name: "Take instrument live")
    var track = Track(id: UUID(), name: "Track", role: .other); track.clips = [clip]
    project.songs[0].tracks = [track]
    func render(_ project: Project, subplay: Bool = false, bypassEnv: Bool = false, rapidTempo: Bool = false, expectedErrors: Int = 0, boundedCache: Bool = false, reuseRetired: Float? = nil) throws -> ([Float], [Float]) {
        let engine = AVAudioEngine(); try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 128)
        let audio = StemAudioPlayback(engine: engine, realtime: false); audio.open(directory: directory)
        defer { audio.prepareForClosing() }
        var errors = 0; audio.onError = { _ in errors += 1 }
        var state = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id,
            position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: subplay, position: subplay ? 1 : 0)))
        var revision: UInt64 = 1
        try audio.update(state, revision: revision)
        let initialTakeEffects = reuseRetired == nil ? nil : audio.effects(for: project.songs[0].tracks[0].clips[0].id)
        var reusedItem: UUID?
        let firstNodes = engine.attachedNodes
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
        var output = ([Float](), [Float]()), promoted = false, disabled = false
        var lastTime = 0.0, tempoEdits = 0, sought = false
        while engine.manualRenderingSampleTime < Int64(rate * 4) {
            let time = Double(engine.manualRenderingSampleTime) / rate
            if rapidTempo { state.transport.position += time - lastTime }
            else { state.transport.position = time + (promoted ? 1 : 0) }
            lastTime = time
            if rapidTempo && tempoEdits < 40 && time >= 0.6 + Double(tempoEdits) * 0.04 {
                let before = state.project.songs[0]; var after = before
                after.markers![0].tempoBPM! += tempoEdits.isMultiple(of: 2) ? 1 : -1
                let map = TempoEditMap(before: before, after: after)
                map.apply(to: &after); map.apply(to: &state.transport)
                state.project.songs[0] = after; tempoEdits += 1; revision += 1
            }
            if rapidTempo && time >= 2.8 && !sought {
                state.transport.position = 1; sought = true
            }
            state.transport.subPlay.position = time + 1
            if subplay && time >= 1 && !promoted {
                state.transport.subPlayPromotion = 1; state.transport.subPlay.playing = false
                state.transport.position = time + 1; promoted = true
            }
            if let value = reuseRetired, time >= 1.1, reusedItem == nil {
                var next = state.project.songs[0].tracks[0].clips[0]
                next.id = UUID(); next.startTime = 3.2; next.duration = 0.6; next.automation = nil
                if value != 0.5 { next.fx!.externalPlugins![1].componentState = preset(value) }
                state.project.songs[0].tracks[0].clips.append(next); reusedItem = next.id; revision += 1
            }
            if bypassEnv && time >= 1.5 && !disabled {
                state.project.songs[0].tracks[0].clips[0].automation?.enabled = false
                revision += 1; disabled = true
            }
            try audio.update(state, revision: revision)
            if let reusedItem, time < 1.2 {
                precondition(audio.effects(for: reusedItem) === initialTakeEffects, "The next take must reuse the retired main-head plugin graph in this regression")
            }
            if !subplay && !boundedCache { precondition(engine.attachedNodes == firstNodes, "Take playback must preserve its plugin instances") }
            if try engine.renderOffline(128, to: pcm) == .success {
                for channel in 0..<2 {
                    let values = Array(UnsafeBufferPointer(start: pcm.floatChannelData![channel], count: Int(pcm.frameLength)))
                    if channel == 0 { output.0 += values } else { output.1 += values }
                }
            }
        }
        audio.stop()
        if boundedCache {
            let properties = Mirror(reflecting: audio).children
            let active = properties.first(where: { $0.label == "midiTakeVoices" }).map { Mirror(reflecting: $0.value).children.count } ?? 0
            let retired = properties.first(where: { $0.label == "retiredMIDITakeVoices" }).map { Mirror(reflecting: $0.value).children.count } ?? 0
            precondition(active + retired <= 8, "A long show must not retain every inactive take instrument forever")
        }
        precondition(errors == expectedErrors, "Report each cached take-plugin failure once, not on every tick")
        if rapidTempo { precondition(tempoEdits == 40 && sought) }
        return output
    }
    func rms(_ data: [Float], _ time: Double) -> Double {
        let first = Int(time*rate), count = Int(rate*0.08)
        return sqrt(data[first..<first+count].reduce(0) { $0 + Double($1*$1) } / Double(count))
    }
    func preset(_ value: Float) -> String {
        var value = value
        return withUnsafeBytes(of: &value) { Data($0).base64EncodedString() }
    }
    // An item ten seconds away is not prepared by the normal two-second
    // lookahead. Opening its editor must prepare a silent instance, and both
    // a preview and its cancellation must survive ordinary transport ticks.
    func coldEditor(_ midi: Bool) throws {
        var synth = plugin(); synth.componentState = preset(0.5)
        var item = clip; item.startTime = 10; item.fx = chain(midi ? [plugin(true), synth] : [synth])
        if !midi {
            let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate*3))!
            tone.frameLength = tone.frameCapacity
            for channel in 0..<2 { for frame in 0..<Int(tone.frameLength) { tone.floatChannelData![channel][frame] = 0.2 } }
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent("editor.wav"), settings: format.settings)
            try file.write(from: tone)
            item.midi = nil; item.audioFile = AudioFile(path: "editor.wav")
        }
        var editedProject = project; editedProject.songs[0].tracks[0].clips = [item]
        let engine = AVAudioEngine(); try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 128)
        let audio = StemAudioPlayback(engine: engine, realtime: false); audio.open(directory: directory)
        defer { audio.prepareForClosing() }
        var state = ShowSnapshot(project: editedProject, transport: TransportState(playing: false, songId: editedProject.songs[0].id,
            position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
        try audio.update(state, revision: 1)
        audio.observeEffect(item.id, effect: synth.effectKey, active: true)
        guard let fx = audio.effects(for: item.id), let node = fx.externalNode(synth.id) else { fatalError("Cold item editor must prepare its external plugin") }
        var changed = item.fx!; changed.externalPlugins![changed.externalPlugins!.count-1].componentState = preset(0.8)
        audio.previewClipFX(item.id, settings: changed)
        try audio.update(state, revision: 1)
        precondition(audio.effects(for: item.id) === fx && fx.externalNode(synth.id) === node)
        let parameter = JarasVST3.parameters(node, identifier: synth.id).first { ($0["id"] as? UInt32) == 0 }!["value"] as! Double
        precondition(abs(parameter-0.8)<0.001, "Idle preview must not revert on the next transport update")
        state.transport.playing = true
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
        var output = [Float](), reverted = false
        while engine.manualRenderingSampleTime < Int64(rate*1.2) {
            let time = Double(engine.manualRenderingSampleTime)/rate
            state.transport.position = 10+time
            if time >= 0.7 && !reverted { audio.previewClipFX(item.id, settings: item.fx!); reverted = true }
            try audio.update(state, revision: 1)
            precondition(audio.effects(for: item.id) === fx && fx.externalNode(synth.id) === node,
                         "Play must adopt the preplay editor instance without replacing its UI or state")
            if try engine.renderOffline(128, to: pcm) == .success {
                output += Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
            }
        }
        print("COLD_ITEM_EDITOR_PCM", midi, rms(output,0.4), rms(output,0.95))
        precondition(abs(rms(output,0.4)/rms(output,0.95)-1.6)<0.03, "Live PCM must honor preview and revert for a cold audio/MIDI item")
        audio.observeEffect(item.id, effect: synth.effectKey, active: false)
        print("COLD_ITEM_EDITOR_PREVIEW_REVERT_SAME_INSTANCE_PCM_OK", midi ? "MIDI" : "AUDIO", rate)
    }
    try coldEditor(true)
    try coldEditor(false)
    let baseline = try render(project)
    print("MIDI_TAKE_BASELINE", rate, rms(baseline.0,0.5), rms(baseline.1,0.5))
    precondition(abs(rms(baseline.0,0.5)-0.025)<0.002 && rms(baseline.1,0.5)<1e-6,
                 "Take instrument and following take FX must generate PCM without a track instrument; gain and pan are post-instrument")
    precondition(rms(baseline.0,3.3)<1e-6, "Item end must release its instrument notes")
    var neighbour = clip; neighbour.id = UUID(); neighbour.name = "Second instance"; neighbour.gain = 0.2; neighbour.pan = 1
    var inactive = clip; inactive.id = UUID(); inactive.muted = true
    project.songs[0].tracks[0].clips += [neighbour, inactive]
    let overlapping = try render(project)
    precondition(abs(rms(overlapping.0,0.5)/rms(baseline.0,0.5)-1)<0.01 && abs(rms(overlapping.1,0.5)/rms(baseline.0,0.5)-0.5)<0.01,
                 "Overlapping takes sharing plugin IDs must have isolated instrument instances; inactive takes stay silent")
    project.songs[0].tracks[0].clips = [clip]
    project.songs[0].tracks[0].fx = chain([plugin()])
    let trackFX = try render(project)
    precondition(abs(rms(trackFX.0,0.5)/rms(baseline.0,0.5)-0.5)<0.01, "Take instrument output must pass through owning track FX")
    project.songs[0].tracks[0].fx = chain([plugin(true)])
    let noDouble = try render(project)
    // An instrument insert retains dry input plus its processed input (1.5x),
    // but must receive no take notes, which would add another 0.125 here.
    precondition(abs(rms(noDouble.0,0.5)/rms(baseline.0,0.5)-1.5)<0.03, "Take notes must not also trigger the track instrument")
    project.songs[0].tracks[0].fx = nil
    var automation = TrackAutomation()
    var volume = TrackEnvelope(target: AutomationTarget(.volume), name: "Take volume", defaultValue: TrackEnvelope.normalizedGain(1))
    volume.points = [.init(time: 0, value: TrackEnvelope.normalizedGain(1), shape: .square), .init(time: 1, value: TrackEnvelope.normalizedGain(0.5), shape: .square)]
    var external = TrackEnvelope(target: AutomationTarget(.externalFX, plugin: takeEffect.id, parameter: 0), name: "Take effect", defaultValue: 0.5)
    external.points = [.init(time: 0, value: 0.8, shape: .square), .init(time: 1, value: 0.2, shape: .square)]
    automation.envelopes = [volume,external]; clip.automation = automation; project.songs[0].tracks[0].clips = [clip]
    let automated = try render(project, bypassEnv: true)
    precondition(abs(rms(automated.0,0.5)/rms(automated.0,1.2)-8)<0.1, "MIDI take volume and VST3 envelopes must affect only its generated PCM")
    precondition(abs(rms(automated.0,2)/rms(baseline.0,2)-1)<0.02, "Disabling take Env restores manual gain and plugin parameter")
    clip.automation = nil; project.songs[0].tracks[0].clips = [clip]
    let promoted = try render(project, subplay: true)
    precondition(abs(rms(promoted.0,0.5)/rms(baseline.0,0.5)-2)<0.02, "Main/subplay take instances must sound independently")
    precondition(abs(rms(promoted.0,1.4)/rms(baseline.0,0.5)-1)<0.02 && rms(promoted.0,2.3)<1e-6,
                 "Promoting Sub Play must preserve incoming notes, retire previous head, and respect its item end")
    var reusedProject = project
    var constant = external; constant.points = [.init(time: 0, value: 0.8, shape: .square)]
    var reusedAutomation = TrackAutomation(); reusedAutomation.envelopes = [constant]
    reusedProject.songs[0].tracks[0].clips[0].automation = reusedAutomation
    for value: Float in [0.5,0.8] {
        let reused = try render(reusedProject, subplay: true, reuseRetired: value)
        precondition(abs(rms(reused.0,2.5)/rms(baseline.0,0.5)-Double(value)/0.5)<0.03,
                     "Retired voice reuse must restore old automation before applying same-ID plugin state of the next take")
    }
    print("MIDI_TAKE_RETIRED_AUTOMATION_RESTORE_SAME_AND_CHANGED_PRESET_PCM_OK", rate)
    var cachedProject = project
    cachedProject.songs[0].tracks[0].clips = (0..<18).map { index in
        var item = clip; item.id = UUID(); item.startTime = Double(index)*0.1; item.duration = 0.08
        item.midi!.notes[0].length = 0.16; return item
    }
    _ = try render(cachedProject, boundedCache: true)
    // A bad early insert cannot prevent a valid later one from being loaded.
    let engine = AVAudioEngine(), source = AVAudioMixerNode(), sink = AVAudioMixerNode()
    engine.attach(source); engine.attach(sink)
    let effects = NativeEffectsChain(); effects.attach(to: engine, input: source, format: format, destinations: [AVAudioConnectionPoint(node: sink, bus: 0)])
    var broken = plugin(); broken.path = directory.appendingPathComponent("Missing.vst3").path
    let valid = plugin(); effects.apply(chain([broken, valid]))
    precondition(effects.externalNode(valid.id) != nil && effects.externalError != nil, "Prepare later valid inserts after a failed plugin, while keeping the error visible")
    let prepared = effects.externalNode(valid.id)
    effects.apply(chain([broken,valid]))
    precondition(effects.externalNode(valid.id) === prepared && effects.externalError != nil)
    effects.detach(from: engine)
    project.songs[0].tracks[0].clips[0].fx = chain([broken, takeInstrument, takeEffect])
    let recovered = try render(project, expectedErrors: 1)
    precondition(abs(rms(recovered.0,0.5)/rms(baseline.0,0.5)-1)<0.02, "A failed early insert must not silence a later valid take instrument")
    if let attackPath = ProcessInfo.processInfo.environment["JARAS_TEST_MIDI_ATTACK_VST3"] {
        var instrument = takeInstrument; instrument.path = attackPath
        var held = clip; held.duration = 6; held.midi!.notes[0].length = 12; held.fx = chain([instrument])
        project.songs[0].tracks[0].clips = [held]
        project.songs[0].markers = [TimelineMarker(id: UUID(), name: "Tempo", position: 0, color: 0,
            tempoBPM: 120, tempoTimebase: .relative, tempoReferenceBPM: 120)]
        let edited = try render(project, rapidTempo: true)
        let amplitude = rms(edited.0,0.4)
        for time in stride(from: 0.7, through: 2.6, by: 0.1) {
            precondition(abs(rms(edited.0,time)/amplitude-1)<0.02, "Rapid BPM edits must not retrigger a held MIDI take note")
        }
        precondition(abs(rms(edited.0,3.2)/amplitude-2)<0.02, "A real seek must still chase/retrigger the held note")
        print("MIDI_TAKE_40_RAPID_TEMPO_EDITS_NO_ATTACK_RESTART_REAL_SEEK_CHASE_PCM_OK", rate)
    }
    print("MIDI_TAKE_INSTRUMENT_TRACK_FX_ISOLATION_ENV_SUBPLAY_PROMOTION_AND_END_PCM_OK", rate)
}
try MainActor.assumeIsolated { try run() }
