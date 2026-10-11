import Foundation
import AVFoundation
import Darwin
setbuf(stdout, nil)
@MainActor func run() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate*5))!; source.frameLength = source.frameCapacity
    for channel in 0..<2 { for frame in 0..<Int(source.frameLength) { source.floatChannelData![channel][frame] = Float(0.01*sin(2*Double.pi*440*Double(frame)/rate)) } }
    do { let file = try AVAudioFile(forWriting: directory.appendingPathComponent("tone.wav"), settings: format.settings); try file.write(from: source) }
    func curve(_ kind: AutomationTarget.Kind, _ values: [(Double,Double)]) -> TrackEnvelope {
        var envelope = TrackEnvelope(target: AutomationTarget(kind), name: kind.rawValue, defaultValue: kind == .volume ? TrackEnvelope.normalizedGain(1) : 0.5)
        envelope.points = values.map { EnvelopePoint(time: $0.0, value: $0.1, shape: .square) }; return envelope
    }
    func render(_ project: Project, bypassAt: Double? = nil, hideLanesAt: Double? = nil, showLanesAt: Double? = nil) throws -> ([Float], [Float], Int) {
        let engine = AVAudioEngine(); try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
        let audio = StemAudioPlayback(engine: engine, realtime: false); audio.open(directory: directory)
        defer { audio.prepareForClosing() }
        var state = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
        var left: [Float] = [], right: [Float] = [], revision: UInt64 = 1
        var didBypass = false, didHideLanes = false, didShowLanes = false
        try audio.update(state, revision: revision)
        let originalNodes = engine.attachedNodes
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        while engine.manualRenderingSampleTime < Int64(rate*4) {
            let time = Double(engine.manualRenderingSampleTime)/rate
            state.transport.position = time
            if let bypassAt, time >= bypassAt, !didBypass {
                state.project.songs[0].tracks[0].automation?.enabled = false; state.project.masterAutomation?.enabled = false
                for index in state.project.songs[0].tracks[0].clips.indices { state.project.songs[0].tracks[0].clips[index].automation?.enabled = false }
                revision += 1; didBypass = true
            }
            if let hideLanesAt, time >= hideLanesAt, !didHideLanes {
                state.project.songs[0].tracks[0].automation?.lanesVisible = false
                state.project.songs[0].tracks[0].automation?.enabled = false
                state.project.masterAutomation?.lanesVisible = false
                state.project.masterAutomation?.enabled = false
                revision += 1; didHideLanes = true
            }
            if let showLanesAt, time >= showLanesAt, !didShowLanes {
                state.project.songs[0].tracks[0].automation?.lanesVisible = true
                state.project.songs[0].tracks[0].automation?.enabled = true
                state.project.masterAutomation?.lanesVisible = true
                state.project.masterAutomation?.enabled = true
                revision += 1; didShowLanes = true
            }
            try audio.update(state, revision: revision)
            precondition(engine.attachedNodes == originalNodes, "Envelope playback must not recreate audio nodes")
            if try engine.renderOffline(256, to: pcm) == .success {
                left += Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
                right += Array(UnsafeBufferPointer(start: pcm.floatChannelData![1], count: Int(pcm.frameLength)))
            }
        }
        return (left, right, originalNodes.count)
    }
    func rms(_ data: [Float], _ time: Double) -> Double {
        let first = Int(time*rate), length = Int(0.1*rate)
        return sqrt(data[first..<first+length].reduce(0) { $0+Double($1*$1) } / Double(length))
    }
    func assertSamePCM(_ lhs: ([Float], [Float], Int), _ rhs: ([Float], [Float], Int), at time: Double, _ reason: String) {
        precondition(lhs.0.count == rhs.0.count && lhs.1.count == rhs.1.count && lhs.2 == rhs.2)
        let frames = Int(time*rate)..<Int((time+0.1)*rate)
        let leftError = zip(lhs.0[frames], rhs.0[frames]).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        let rightError = zip(lhs.1[frames], rhs.1[frames]).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        precondition(leftError < 1e-7 && rightError < 1e-7, reason)
    }
    var project = Project.empty(name: "Envelope PCM")
    var track = Track(id: UUID(), name: "Audio", role: .other)
    track.clips = [AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 4.5, audioFile: AudioFile(path: "tone.wav"))]
    var automation = TrackAutomation(); automation.mode = .read
    automation.envelopes = [curve(.volume, [(0, TrackEnvelope.normalizedGain(0.5)), (1, TrackEnvelope.normalizedGain(0.25))]), curve(.pan, [(0,0), (2,1)])]
    track.automation = automation; project.songs[0].tracks = [track]
    var master = TrackAutomation(); master.mode = .read; master.envelopes = [curve(.volume, [(0,TrackEnvelope.normalizedGain(2))])]; project.masterAutomation = master
    let result = try render(project)
    let a = rms(result.0, 0.5), b = rms(result.0, 1.5), c = rms(result.1, 2.5)
    print("AUTOMATION_PCM", rate, a, b, c)
    precondition(a > 0.003 && abs(a/b-2)<0.06 && abs(b/c-1)<0.06, "Track/master envelopes must affect actual PCM gain")
    precondition(rms(result.1,0.5)<0.00001 && rms(result.0,2.5)<0.00001, "Pan envelopes must route channels")
    var hiddenPanProject = project
    hiddenPanProject.songs[0].tracks[0].automation?.envelopes[1].visible = false
    let hiddenPan = try render(hiddenPanProject)
    precondition(abs(rms(hiddenPan.0,0.5)/rms(hiddenPan.1,0.5)-1)<0.01 && abs(rms(hiddenPan.0,2.5)/rms(hiddenPan.1,2.5)-1)<0.01,
                 "An individually hidden pan curve must leave the manual pan in control")
    precondition(abs(rms(hiddenPan.0,0.5)/rms(hiddenPan.0,1.5)-2)<0.06,
                 "Hiding pan must preserve playback of the visible volume curve")
    var manualProject = project
    manualProject.songs[0].tracks[0].automation = nil; manualProject.masterAutomation = nil
    let manual = try render(manualProject)
    let hiddenLanes = try render(project, hideLanesAt: 1.5)
    assertSamePCM(hiddenLanes, manual, at: 1.7, "Env OFF must restore manual track/master volume and pan")
    assertSamePCM(hiddenLanes, manual, at: 2.2, "The later pan point must not act while Env is off")
    assertSamePCM(hiddenLanes, manual, at: 3.2, "Hidden lanes must remain inactive")
    let resumedLanes = try render(project, hideLanesAt: 1.5, showLanesAt: 2.5)
    assertSamePCM(resumedLanes, manual, at: 2.2, "Env remains bypassed until switched back on")
    assertSamePCM(resumedLanes, result, at: 2.7, "Env ON must resume the values at the current timeline cursor without rewinding")
    assertSamePCM(resumedLanes, result, at: 3.2, "Reenabled envelopes must continue following the current timeline")
    let bypass = try render(project, bypassAt: 3)
    precondition(abs(rms(bypass.0,3.5)/rms(bypass.1,3.5)-1)<0.01, "Bypass restores manual pan")
    var fx = NativeFXSettings(); _ = fx.appendNative("Compressor"); fx.threshold = 0; fx.makeup = 3
    project.masterAutomation = nil; project.songs[0].tracks[0].fx = fx
    let parameter = NativeFXParameter(effect: "Compressor", key: .makeup, name: "Gain", range: -12...24)
    var gain = TrackEnvelope(target: AutomationTarget(.nativeFX, native: parameter), name: "Compressor gain", defaultValue: parameter.normalized(3))
    gain.points = [.init(time: 0, value: parameter.normalized(6), shape: .square), .init(time: 2, value: parameter.normalized(0), shape: .square)]
    automation.envelopes = [gain]; project.songs[0].tracks[0].automation = automation
    let native = try render(project)
    precondition(abs(rms(native.0,0.5)/rms(native.0,2.5)-pow(10,6.0/20))<0.08, "Native plugin parameters must change PCM")
    var manualNativeProject = project; manualNativeProject.songs[0].tracks[0].automation = nil
    let manualNative = try render(manualNativeProject)
    let nativeToggled = try render(project, hideLanesAt: 1.5, showLanesAt: 2.5)
    assertSamePCM(nativeToggled, manualNative, at: 1.7, "Env OFF must restore the manual native plugin gain")
    assertSamePCM(nativeToggled, manualNative, at: 2.2, "Hidden native FX points must not alter the plugin")
    assertSamePCM(nativeToggled, native, at: 2.7, "Env ON resumes the native plugin curve at the current position")
    // The same chain and envelope are valid on Master, with no instrument.
    project.songs[0].tracks[0].fx = nil; project.songs[0].tracks[0].automation = nil
    project.masterFX = fx; project.masterAutomation = automation
    let masterFX = try render(project)
    precondition(abs(rms(masterFX.0,0.5)/rms(masterFX.0,2.5)-pow(10,6.0/20))<0.08, "Master plugin envelopes must change PCM")
    var manualMasterProject = project; manualMasterProject.masterAutomation = nil
    let manualMaster = try render(manualMasterProject)
    let masterToggled = try render(project, hideLanesAt: 1.5, showLanesAt: 2.5)
    assertSamePCM(masterToggled, manualMaster, at: 2.2, "Env OFF must restore the manual Master plugin gain")
    assertSamePCM(masterToggled, masterFX, at: 2.7, "Env ON resumes the Master plugin curve at the current position")
    // An offset, slowed take shares the track with another audible item. Its
    // envelope follows media time and must not touch the neighbour or track.
    var itemProject = Project.empty(name: "Take automation PCM")
    var itemTrack = Track(id: UUID(), name: "Two takes", role: .other)
    var take = AudioClip(id: UUID(), name: "Automated take", startTime: 0, duration: 4.5, sourceOffset: 0.5,
                         audioFile: AudioFile(path: "tone.wav"), gain: 0.5, pan: -1, playbackRate: 0.5)
    var takeAutomation = TrackAutomation(); takeAutomation.lanesVisible = false
    var takeVolume = curve(.volume, [(0.5, TrackEnvelope.normalizedGain(1)), (1, TrackEnvelope.normalizedGain(0.5)), (1.5, TrackEnvelope.normalizedGain(0.25))])
    takeVolume.visible = false; takeAutomation.envelopes = [takeVolume]; take.automation = takeAutomation
    let neighbour = AudioClip(id: UUID(), name: "Unaffected neighbour", startTime: 0, duration: 4.5,
                              audioFile: AudioFile(path: "tone.wav"), gain: 0.3, pan: 1)
    itemTrack.clips = [take, neighbour]; itemProject.songs[0].tracks = [itemTrack]
    let core = JarasCoreBridge()
    try core.load(projectData: JSONEncoder().encode(itemProject))
    var bridgeState = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
    precondition(bridgeState.project.songs[0].tracks[0].clips[0].automation == takeAutomation, "Core bridge must retain take envelopes")
    try core.replaceAudioClip(JSONEncoder().encode(take), track: itemTrack.id.uuidString)
    bridgeState = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
    precondition(bridgeState.project.songs[0].tracks[0].clips[0].automation == takeAutomation, "Replacing an item must preserve its automation")
    try core.load(projectData: JSONEncoder().encode(bridgeState.project))
    bridgeState = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot())
    precondition(bridgeState.project.songs[0].tracks[0].clips[0].automation == takeAutomation, "Reopening a project must retain take envelopes")
    let takeOutput = try render(itemProject)
    precondition(abs(rms(takeOutput.0,0.5)/rms(takeOutput.0,1.5)-2)<0.08 && abs(rms(takeOutput.0,1.5)/rms(takeOutput.0,2.5)-2)<0.08,
                 "Take gain follows source offset/playrate, multiplies item gain and plays while its display is hidden")
    precondition(abs(rms(takeOutput.1,0.5)/rms(takeOutput.1,2.5)-1)<0.01, "An overlapping take on the same track must keep its original gain")
    let takeBypass = try render(itemProject, bypassAt: 3)
    precondition(abs(rms(takeBypass.0,3.5)/rms(takeOutput.0,2.5)-4)<0.15, "Disabling take automation restores its own manual gain")
    itemProject.songs[0].tracks[0].clips[0].pan = 0
    itemProject.songs[0].tracks[0].clips[0].automation?.envelopes = [curve(.pan, [(0.5,0), (1.5,1)])]
    let takePan = try render(itemProject)
    precondition(rms(takePan.0,0.5)>0.003 && rms(takePan.0,2.5)<0.00001, "Take pan must affect the individual voice")
    itemProject.songs[0].tracks[0].clips[0].pan = -1
    itemProject.songs[0].tracks[0].clips[0].fx = fx
    var takeFX = gain; takeFX.points = [.init(time: 0.5, value: parameter.normalized(6), shape: .square), .init(time: 1.5, value: parameter.normalized(0), shape: .square)]
    itemProject.songs[0].tracks[0].clips[0].automation?.envelopes = [takeFX]
    let takeNative = try render(itemProject)
    precondition(abs(rms(takeNative.0,0.5)/rms(takeNative.0,2.5)-pow(10,6.0/20))<0.1, "Take native FX automation must affect PCM")
    precondition(abs(rms(takeNative.1,0.5)/rms(takeNative.1,2.5)-1)<0.01, "Take FX must not modify its track neighbour")
    print("ITEM_AUTOMATION_OFFSET_RATE_VOLUME_PAN_NATIVE_ISOLATED_PCM_OK", rate)
    if let path = ProcessInfo.processInfo.environment["JARAS_TEST_VST3"] {
        var error: NSError?
        let descriptor = JarasVST3.scan(path, error: &error)[0]
        let plugin = ExternalPlugin(classID: descriptor["classID"] as! String, name: "Gain fixture", path: path)
        var external = NativeFXSettings(); external.inserted = [plugin.effectKey]; external.externalPlugins = [plugin]
        var parameter = TrackEnvelope(target: AutomationTarget(.externalFX, plugin: plugin.id, parameter: 0), name: "VST3 Gain", defaultValue: 0.5)
        parameter.points = [.init(time: 0, value: 0.8, shape: .square), .init(time: 2, value: 0.2, shape: .square)]
        var controls = TrackAutomation(); controls.mode = .read; controls.envelopes = [parameter]
        project.masterFX = external; project.masterAutomation = controls
        let output = try render(project)
        var manualExternalProject = project; manualExternalProject.masterAutomation = nil
        let manualExternal = try render(manualExternalProject)
        let externalToggled = try render(project, hideLanesAt: 1.5, showLanesAt: 2.5)
        assertSamePCM(externalToggled, manualExternal, at: 2.2, "Env OFF must restore the manual external plugin gain")
        assertSamePCM(externalToggled, output, at: 2.7, "Env ON resumes the external plugin curve at the current position")
        print("VST3_ENVELOPE_RATIO", rms(output.0,0.5)/rms(output.0,2.5))
        precondition(abs(rms(output.0,0.5)/rms(output.0,2.5)-4)<0.03, "VST3 parameter envelope must alter the actual Master output")
        let bypassed = try render(project, bypassAt: 3)
        precondition(abs(rms(bypassed.0,3.5)/rms(output.0,2.5)-2.5)<0.03, "Bypassing external automation restores the plugin parameter")
        print("EXTERNAL_MASTER_AUTOMATION_OK", rate)
        itemProject.songs[0].tracks[0].clips[0].fx = external
        parameter.points = [.init(time: 0.5, value: 0.8, shape: .square), .init(time: 1.5, value: 0.2, shape: .square)]
        itemProject.songs[0].tracks[0].clips[0].automation?.envelopes = [parameter]
        try itemProject.validate()
        try core.load(projectData: JSONEncoder().encode(itemProject))
        let externalRoundTrip = try JSONDecoder().decode(ShowSnapshot.self, from: core.metadataSnapshot()).project.songs[0].tracks[0].clips[0]
        precondition(externalRoundTrip.fx == external && externalRoundTrip.automation == itemProject.songs[0].tracks[0].clips[0].automation,
                     "Take VST3 chain and parameter curves must survive the core bridge together")
        let takeExternal = try render(itemProject)
        precondition(abs(rms(takeExternal.0,0.5)/rms(takeExternal.0,2.5)-4)<0.1, "Take VST3 parameters must change only that item's PCM")
        precondition(abs(rms(takeExternal.1,0.5)/rms(takeExternal.1,2.5)-1)<0.01, "External take FX must preserve neighbour PCM")
        let takeExternalBypass = try render(itemProject, bypassAt: 3)
        precondition(abs(rms(takeExternalBypass.0,3.5)/rms(takeExternal.0,2.5)-2.5)<0.08, "Take automation bypass must restore original VST3 parameter")
        print("EXTERNAL_ITEM_AUTOMATION_ISOLATION_PCM_OK", rate)
    }
    print("AUTOMATION_ENV_OFF_RESTORES_MANUAL_ON_RESUMES_CURRENT_CURSOR_GAIN_PAN_NATIVE_MASTER_OK", rate)
    print("AUTOMATION_GAIN_PAN_BYPASS_NATIVE_MASTER_OK", rate)
}
Task { @MainActor in do { try run(); exit(0) } catch { print(error); exit(1) } }
dispatchMain()
