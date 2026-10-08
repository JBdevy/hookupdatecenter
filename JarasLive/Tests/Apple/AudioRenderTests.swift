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
// First use of dormant group/internal sends must preserve scheduled file
// position, item tails and the continuously attached live input.
do {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let routeFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    do {
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("routing-phase.wav"), settings: routeFormat.settings)
        let sourcePCM = AVAudioPCMBuffer(pcmFormat: routeFormat, frameCapacity: AVAudioFrameCount(rate * 3))!
        sourcePCM.frameLength = sourcePCM.frameCapacity
        for channel in 0..<2 { for frame in 0..<Int(sourcePCM.frameLength) {
            let t = Double(frame) / rate
            sourcePCM.floatChannelData![channel][frame] = Float(0.06 * sin(2 * .pi * Double(331 + channel * 97) * t) + 0.02 * t)
        } }
        try file.write(from: sourcePCM)
    }
    var project = Project.empty(name: "Dormant sends")
    let parent = Track(id: UUID(), name: "Parent", role: .other)
    let receiver = Track(id: UUID(), name: "Receiver", role: .other)
    var child = Track(id: UUID(), name: "Source", role: .other)
    child.parentTrackID = parent.id; child.outputs = [.master]
    var fx = NativeFXSettings()
    fx.delayEnabled = true; fx.delayTime = 0.15; fx.delayMix = 35; fx.feedback = 55
    fx.reverbEnabled = true; fx.reverbMix = 30; fx.reverbDecay = 1
    child.clips = [AudioClip(id: UUID(), name: "Continuous phase", startTime: 0, duration: 96 * 512 / rate,
                            audioFile: AudioFile(path: "routing-phase.wav"), fx: fx)]
    project.songs[0].tracks = [parent, receiver, child]
    var state = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id,
        position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    func makeRenderer() throws -> (AVAudioEngine, StemAudioPlayback) {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: routeFormat, maximumFrameCount: 512)
        let audio = StemAudioPlayback(engine: engine, realtime: false)
        audio.open(directory: directory)
        try audio.update(state, revision: 1)
        let monitor = AVAudioSourceNode(format: routeFormat) { silent, _, frames, buffers in
            silent.pointee = false
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                buffer.mData!.assumingMemoryBound(to: Float.self).update(repeating: 0.003, count: Int(frames))
            }
            return noErr
        }
        audio.setInputMonitor(child.id, source: monitor, format: routeFormat)
        return (engine, audio)
    }
    let (referenceEngine, referenceAudio) = try makeRenderer()
    let (changingEngine, changingAudio) = try makeRenderer()
    defer { referenceAudio.prepareForClosing(); changingAudio.prepareForClosing() }
    let referencePCM = AVAudioPCMBuffer(pcmFormat: routeFormat, frameCapacity: 512)!
    let changingPCM = AVAudioPCMBuffer(pcmFormat: routeFormat, frameCapacity: 512)!
    let originalNodes = changingEngine.attachedNodes
    var capturedMIDI: [UInt8] = []
    changingAudio.armedMIDIRecordingTracks = [child.id]
    changingAudio.onLiveKeyboardMIDI = { _, status, _, _ in capturedMIDI.append(status) }
    var changedAt = -100, largestError: Float = 0, tailPeak: Float = 0
    for block in 0..<224 {
        state.transport.position = Double(block * 512) / rate
        try referenceAudio.update(state, revision: 1); try changingAudio.update(state, revision: 1)
        if block > 0 && block % 24 == 0 && block <= 192 {
            switch (block / 24 - 1) % 4 {
            case 0: changingAudio.previewPatches(child.id, patches: [.masterGroup])
            case 1: changingAudio.previewPatches(child.id, patches: [.master])
            case 2:
                changingAudio.previewPatches(child.id, patches: [.none])
                changingAudio.previewRouting([child.id: TrackRouting(transmitters: [receiver.id])])
            default:
                changingAudio.previewPatches(child.id, patches: [.master])
                changingAudio.previewRouting([child.id: TrackRouting()])
            }
            changingAudio.playKeyboardNote(60); changingAudio.releaseKeyboardNote(60)
            changedAt = block
        }
        let referenceStatus = try referenceEngine.renderOffline(512, to: referencePCM)
        let changingStatus = try changingEngine.renderOffline(512, to: changingPCM)
        precondition(referenceStatus == .success && changingStatus == .success)
        precondition(changingEngine.isRunning && changingEngine.attachedNodes == originalNodes,
                     "routing activates prepared sends without replacing players, effects or live input")
        if block > 8 && block - changedAt > 4 {
            for channel in 0..<2 { for frame in 0..<512 {
                largestError = max(largestError, abs(referencePCM.floatChannelData![channel][frame] - changingPCM.floatChannelData![channel][frame]))
                if block >= 160 { tailPeak = max(tailPeak, abs(changingPCM.floatChannelData![channel][frame] - 0.003)) }
            } }
        }
    }
    precondition(largestError < 0.0001, "routing preserves sample position and wet PCM through live Master/group/internal cycles: \(largestError)")
    precondition(tailPeak > 0.00001, "item effect tails remain audible across routing changes after the file ends")
    precondition(changingAudio.hasInputMonitor(child.id) && capturedMIDI == Array(repeating: [UInt8(0x90), 0x80], count: 8).flatMap { $0 },
                 "live monitoring and MIDI capture stay attached through all routing changes")
    print("DORMANT_SEND_LIVE_MASTER_GROUP_INTERNAL_CYCLE_PHASE_TAIL_MONITOR_MIDI_OK rate=\(rate)")
}
// Compare each rendered sample with the established manual-fader path. This
// covers the same DSP smoothing, tails, monitor, linked controls and hardware
// fanout, with no engine reconnects while the automatic amount changes.
do {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!
    let hardware = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
    let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    var project = Project.empty(name: "Internal Auto Fader PCM")
    let group = Track(id: UUID(), name: "Group", role: .other)
    var child = Track(id: UUID(), name: "Wet source", role: .other)
    child.parentTrackID = group.id
    child.outputs = [.masterGroup, OutputPatch(firstChannel: 3, channelCount: 2)]
    var wet = NativeFXSettings(); wet.delayEnabled = true; wet.delayTime = 0.07; wet.delayMix = 35; wet.feedback = 40
    child.clips = [AudioClip(id: UUID(), name: "Tail source", startTime: 0, duration: 0.6,
        audioFile: AudioFile(path: "routing-phase.wav"), fx: wet)]
    let left = Track(id: UUID(), name: "Linked L", role: .other)
    let right = Track(id: UUID(), name: "Linked R", role: .other)
    project.songs[0].tracks = [group, child, left, right]
    project.songs[0].linkTracks([left.id, right.id], firstInput: 1, color: 0)
    project.masterVolume = 0.8; project.masterFX = wet
    var state = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id,
        position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    var rule = MultiLoopTrack(id: child.id, gain: 0.2); rule.autoFader = true
    var pairRule = MultiLoopTrack(id: left.id, gain: 0.3); pairRule.autoFader = true
    var masterRule = MultiLoopTrack(id: MultiLoopTrack.masterID, gain: 0); masterRule.autoFader = true
    let loopID = UUID()
    func attachMonitors(_ audio: StemAudioPlayback) {
        for (id, amplitude) in [(child.id, Float(0.011)), (left.id, Float(0.017)), (right.id, Float(0.029))] {
            let source = AVAudioSourceNode(format: stereo) { silent, _, frames, buffers in
                silent.pointee = false
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    buffer.mData!.assumingMemoryBound(to: Float.self).update(repeating: amplitude, count: Int(frames))
                }
                return noErr
            }
            audio.setInputMonitor(id, source: source, format: stereo)
        }
    }
    func makeAudio() throws -> (AVAudioEngine, StemAudioPlayback) {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: hardware, maximumFrameCount: 512)
        let audio = StemAudioPlayback(engine: engine, realtime: false)
        audio.open(directory: directory); try audio.update(state, revision: 1); attachMonitors(audio)
        return (engine, audio)
    }
    let (referenceEngine, reference) = try makeAudio(), (automatedEngine, automated) = try makeAudio()
    defer { reference.prepareForClosing(); automated.prepareForClosing() }
    let expected = AVAudioPCMBuffer(pcmFormat: hardware, frameCapacity: 512)!
    let actual = AVAudioPCMBuffer(pcmFormat: hardware, frameCapacity: 512)!
    var nodes = automatedEngine.attachedNodes
    var manualChild = 1.0, manualPair = 1.0, manualMaster = 0.8
    var largestError: Float = 0, directAtMasterZero: Float = 0, masterAtZero: Float = 0, tailPeak: Float = 0
    for block in 0..<208 {
        let amount: Double = block < 12 ? 0 : block < 52 ? Double(block - 12) / 40 : block < 76 ? 1 : block < 116 ? Double(116 - block) / 40 : 0.5
        let bypassed = (156..<164).contains(block) || block >= 196
        state.transport.position = Double(block * 512) / rate
        state.transport.playing = !(164..<168).contains(block) && block < 196
        state.transport.paused = (164..<168).contains(block)
        state.transport.multiLoop = bypassed ? nil : MultiLoopPlayback(id: loopID, start: 0, end: 9,
            amount: amount, gates: block >= 52, released: block >= 76, tracks: [rule, pairRule, masterRule])
        state.project.songs[0].tracks[1].volume = manualChild
        state.project.songs[0].tracks[2].volume = manualPair; state.project.songs[0].tracks[3].volume = manualPair
        state.project.masterVolume = manualMaster
        let a = bypassed ? 0 : amount
        func target(_ manual: Double, _ ceiling: Double) -> Double { manual + (min(manual, ceiling) - manual) * a }
        if (132..<140).contains(block) {
            // Conflicting linked presets still arrive through the controller's
            // existing mixer callbacks, and must not receive a second envelope.
            state.transport.multiLoop?.tracks.append(MultiLoopTrack(id: right.id, gain: 0.8))
            state.project.songs[0].tracks[2].volume = target(manualPair, 0.3)
            state.project.songs[0].tracks[3].volume = target(manualPair, 0.3)
            automated.previewVolume(left.id, gain: target(manualPair, 0.3))
            automated.previewVolume(right.id, gain: target(manualPair, 0.3))
        } else if block == 140 {
            automated.previewVolume(left.id, gain: manualPair); automated.previewVolume(right.id, gain: manualPair)
        }
        var referenceState = state; referenceState.transport.multiLoop = nil
        referenceState.project.songs[0].tracks[1].volume = target(manualChild, 0.2)
        referenceState.project.songs[0].tracks[2].volume = target(manualPair, 0.3)
        referenceState.project.songs[0].tracks[3].volume = target(manualPair, 0.3)
        referenceState.project.masterVolume = target(manualMaster, 0)
        reference.previewVolume(child.id, gain: target(manualChild, 0.2))
        reference.previewVolume(left.id, gain: target(manualPair, 0.3)); reference.previewVolume(right.id, gain: target(manualPair, 0.3))
        reference.previewVolume(nil, gain: target(manualMaster, 0))
        let revision: UInt64 = block < 124 ? 1 : 2
        try reference.update(referenceState, revision: revision); try automated.update(state, revision: revision)
        // The gesture happens after the transport update. Its first rendered
        // buffer must already include the cached envelope, without a loud frame.
        if block == 32 {
            manualChild = 0.7; manualPair = 0.6; manualMaster = 0.75
            automated.previewVolume(child.id, gain: manualChild)
            automated.previewVolume(left.id, gain: manualPair); automated.previewVolume(right.id, gain: manualPair)
            automated.previewVolume(nil, gain: manualMaster)
            reference.previewVolume(child.id, gain: target(manualChild, 0.2))
            reference.previewVolume(left.id, gain: target(manualPair, 0.3)); reference.previewVolume(right.id, gain: target(manualPair, 0.3))
            reference.previewVolume(nil, gain: target(manualMaster, 0))
        }
        if block == 144 {
            try reference.reconfigureDevice(); try automated.reconfigureDevice()
        }
        if block == 180 {
            reference.open(directory: directory); automated.open(directory: directory)
            try reference.update(referenceState, revision: revision); try automated.update(state, revision: revision)
            attachMonitors(reference); attachMonitors(automated); nodes = automatedEngine.attachedNodes
        }
        // A real device stays clocked for live input while transport is paused.
        // Keep that same monitor condition in the offline test engine.
        if !referenceEngine.isRunning { try referenceEngine.start() }
        if !automatedEngine.isRunning { try automatedEngine.start() }
        let referenceStatus = try referenceEngine.renderOffline(512, to: expected)
        let automatedStatus = try automatedEngine.renderOffline(512, to: actual)
        precondition(referenceStatus == .success && automatedStatus == .success)
        precondition(automatedEngine.attachedNodes == nodes && automated.hasInputMonitor(child.id), "Auto Fader cannot reconnect sources or monitoring")
        if block > 8 {
            for channel in 0..<4 { for frame in 0..<512 {
                largestError = max(largestError, abs(expected.floatChannelData![channel][frame] - actual.floatChannelData![channel][frame]))
                if (64..<76).contains(block) {
                    if channel < 2 { masterAtZero = max(masterAtZero, abs(actual.floatChannelData![channel][frame])) }
                    else { directAtMasterZero = max(directAtMasterZero, abs(actual.floatChannelData![channel][frame])) }
                }
                if (100..<116).contains(block) && channel == 2 { tailPeak = max(tailPeak, abs(actual.floatChannelData![channel][frame] - 0.011 * Float(target(manualChild, 0.2)))) }
            } }
        }
    }
    precondition(largestError < 0.0001, "internal envelopes must match existing manual-fader PCM, including first gesture buffer and resets: \(largestError)")
    precondition(masterAtZero < 0.00001 && directAtMasterZero > 0.001, "zero Master silences its FX output while direct hardware remains audible")
    precondition(tailPeak > 0.00001, "file effect tails continue through the envelope after the source ends")
    print("INTERNAL_AUTOFADER_PCM_REFERENCE_MONITOR_GROUP_HARDWARE_TAILS_MASTER_ZERO_LINKED_GESTURE_PAUSE_BYPASS_RELOAD_OK rate=\(rate) maxError=\(largestError)")
}
// Item phase/pan use the live production graph and remain local to that item.
do {
    func itemPCM(inverted: Bool, pan: Double, live: Bool = false) throws -> [[Float]] {
        let engine = AVAudioEngine()
        let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let renderer = StemAudioPlayback(engine: engine, realtime: false)
        renderer.open(directory: directory); defer { renderer.prepareForClosing() }
        var project = Project.empty(name: "Item mix")
        var track = Track(id: UUID(), name: "Tone", role: .other)
        let clip = AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 3,
            audioFile: AudioFile(path: "tone.wav"), phaseInverted: live ? false : inverted, pan: live ? 0 : pan)
        track.clips = [clip]; project.songs[0].tracks = [track]
        let state = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id,
            position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
        try renderer.update(state, revision: 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        if live { renderer.previewItemPhase(clip.id, inverted: inverted); renderer.previewItemPan(clip.id, pan: pan) }
        var output = [[Float](), [Float]()]
        for block in 0..<40 {
            let status = try engine.renderOffline(512, to: buffer); precondition(status == .success)
            if block > 24 { for c in 0..<2 { output[c] += Array(UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength))) } }
        }
        return output
    }
    let dry = try itemPCM(inverted: false, pan: 0), inverted = try itemPCM(inverted: true, pan: 0)
    for channel in 0..<2 {
        precondition(dry[channel].contains { abs($0) > 0.05 })
        precondition(zip(dry[channel], inverted[channel]).allSatisfy { abs($0 + $1) < 0.00001 }, "item polarity cancels both source channels")
    }
    for live in [false, true] {
        let left = try itemPCM(inverted: false, pan: -1, live: live)
        let right = try itemPCM(inverted: true, pan: 1, live: live)
        precondition(left[0].contains { $0 > 0.05 } && left[1].allSatisfy { abs($0) < 0.00001 })
        precondition(right[1].contains { $0 < -0.05 } && right[0].allSatisfy { abs($0) < 0.00001 })
    }
    print("ITEM_POLARITY_STEREO_NULL_PAN_AND_LIVE_EDITS_PCM_OK")
}
// Item fades use the whole timeline item clock even after seeking or looping
// the underlying file. Exercise the production voice scheduler, not only the AU.
do {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let fadeFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    for position in [0.0, 1.25] {
        func renderFade(enabled: Bool) throws -> [Float] {
            let fadeEngine = AVAudioEngine()
            try fadeEngine.enableManualRenderingMode(.offline, format: fadeFormat, maximumFrameCount: 512)
            let audio = StemAudioPlayback(engine: fadeEngine, realtime: false)
            audio.open(directory: directory)
            defer { audio.prepareForClosing() }
            var project = Project.empty(name: "Item envelope")
            var track = Track(id: UUID(), name: "Repeated tone", role: .other)
            var clip = AudioClip(id: UUID(), name: "Tone", startTime: 0.5, duration: 3,
                                 audioFile: AudioFile(path: "tone.wav"), loopStart: 0, loopLength: 0.5)
            if enabled { clip.fadeIn = 2.5; clip.fadeOut = 1.5 }
            track.clips = [clip]; project.songs[0].tracks = [track]
            let state = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id,
                    position: position, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
            try audio.update(state, revision: 1)
            let buffer = AVAudioPCMBuffer(pcmFormat: fadeFormat, frameCapacity: 512)!
            var samples: [Float] = []
            for _ in 0..<Int(ceil((3.5-position)*rate/512)) {
                let status = try fadeEngine.renderOffline(512, to: buffer)
                precondition(status == .success)
                samples += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            }
            return samples
        }
        let dry = try renderFade(enabled: false), faded = try renderFade(enabled: true)
        precondition(dry.count == faded.count && dry.contains { abs($0) > 0.05 })
        var error = 0.0
        for i in dry.indices {
            let t = Double(i)/rate + position - 0.5
            func curve(_ input: Double) -> Double { let x = min(1, max(0, input)); return x*x*(3-2*x) }
            error = max(error, abs(Double(faded[i]) - Double(dry[i])*curve(t/2.5)*curve((3-t)/1.5)))
        }
        precondition(error < 0.0003, "production item fade clock at \(position)s / \(rate) Hz: \(error)")
    }
    print("ITEM_FADE_PRODUCTION_SCHEDULER_SEEK_REPEAT_AND_DELAY_OK")
}
// Exercise the production live graph in offline mode: click goes directly to
// selected hardware buses even with Master muted and its fader at silence.
do {
    let settings = MetronomeSettings.shared
    let saved = (settings.enabled, settings.output, settings.preset, settings.gainA, settings.gainB)
    defer { settings.enabled = saved.0; settings.output = saved.1; settings.preset = saved.2; settings.gainA = saved.3; settings.gainB = saved.4 }
    settings.enabled = true; settings.output = .stereo; settings.preset = "Digital"
    settings.gainA = 0; settings.gainB = 0
    let clickEngine = AVAudioEngine()
    let clickFormat = AVAudioFormat(standardFormatWithSampleRate: Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!)
    try clickEngine.enableManualRenderingMode(.offline, format: clickFormat, maximumFrameCount: 512)
    let clickAudio = StemAudioPlayback(engine: clickEngine, realtime: true)
    clickAudio.open(directory: directory)
    defer { clickAudio.prepareForClosing() }
    var project = Project.empty(name: "Direct click")
    project.masterVolume = 0; project.masterMute = true; project.masterMono = true
    let state = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try clickAudio.update(state, revision: 1)
    let generator = Mirror(reflecting: clickAudio).children.first { $0.label == "metronome" }!.value as! JarasMetronomeGenerator?
    let buffer = AVAudioPCMBuffer(pcmFormat: clickFormat, frameCapacity: 512)!
    func clickPeaks() throws -> [Float] {
        generator!.configurePosition(0, hostTime: mach_absolute_time(), running: settings.enabled, loopStart: 0, loopEnd: 0, sampleTime: Double(clickEngine.manualRenderingSampleTime))
        var peaks = [Float](repeating: 0, count: 4)
        for block in 0..<110 {
            if try clickEngine.renderOffline(512, to: buffer) == .success, block > 1 {
                for channel in 0..<4 { for sample in 0..<Int(buffer.frameLength) {
                    peaks[channel] = max(peaks[channel], abs(buffer.floatChannelData![channel][sample]))
                } }
            }
        }
        return peaks
    }
    let stereo = try clickPeaks()
    precondition(stereo[0] > 0.5 && stereo[1] > 0.5 && stereo[2] == 0 && stereo[3] == 0, "default click bypasses muted Master and reaches only 1+2: \(stereo)")
    settings.output = OutputPatch(firstChannel: 3, channelCount: 2)
    let alternate = try clickPeaks()
    precondition(alternate[0] == 0 && alternate[1] == 0 && alternate[2] > 0.5 && alternate[3] > 0.5, "click output changes live to 3+4: \(alternate)")
    settings.output = OutputPatch(firstChannel: 4, channelCount: 1)
    let mono = try clickPeaks()
    precondition(mono[0] == 0 && mono[1] == 0 && mono[2] == 0 && mono[3] > 0.5, "mono click uses only its chosen hardware channel: \(mono)")
    settings.enabled = false
    let off = try clickPeaks()
    precondition(off.allSatisfy { $0 < 0.00001 }, "disabled click stays silent")
    print("METRONOME_DIRECT_OUTPUT_MASTER_BYPASS_STEREO_MONO_LIVE_PATCH_AND_OFF_PCM_OK")
}
// Track polarity reverses PCM; Master never adds a second inversion.
do {
    let phaseEngine = AVAudioEngine()
    let renderFormat = AVAudioFormat(standardFormatWithSampleRate: Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!, channels: 2)!
    try phaseEngine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 512)
    let phaseAudio = StemAudioPlayback(engine: phaseEngine, realtime: false); phaseAudio.open(directory: directory)
    var project = Project.empty(name: "Phase")
    var channel = Track(id: UUID(), name: "Tone", role: .other)
    channel.clips = [AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 10, audioFile: AudioFile(path: "tone.wav"))]
    project.songs[0].tracks = [channel]
    var state = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    let buffer = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: 512)!
    func signedPCM() throws -> Float {
        for _ in 0..<50 { _ = try phaseEngine.renderOffline(512, to: buffer) }
        return buffer.floatChannelData![0][Int(buffer.frameLength) - 1]
    }
    try phaseAudio.update(state, revision: 1)
    let normal = try signedPCM(); precondition(normal > 0.09)
    phaseAudio.previewPhase(channel.id, inverted: true)
    let inverted = try signedPCM(); precondition(abs(inverted + normal) < 0.0001, "track phase reverses PCM")
    phaseAudio.previewPhase(nil, inverted: true)
    let restored = try signedPCM(); precondition(abs(restored - inverted) < 0.0001, "Master phase commands are ignored")
    state.project.masterPhaseInverted = true; state.project.songs[0].tracks[0].phaseInverted = true
    try phaseAudio.update(state, revision: 2)
    let refreshed = try signedPCM(); precondition(abs(refreshed - inverted) < 0.0001, "legacy Master phase cannot reverse track PCM")
    phaseAudio.stop(); phaseEngine.stop()
    print("TRACK_PHASE_PCM_AND_MASTER_PHASE_DISABLED_OK")
}
let engine = AVAudioEngine()
let outputFormat = AVAudioFormat(standardFormatWithSampleRate: Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!, channels: 2)!
// A monitor may prepare its track bus before the snapshot creates meter banks.
// Removing and restoring that track must not revive an unread historical peak.
do {
    let meterEngine = AVAudioEngine()
    try meterEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: meterEngine, realtime: false)
    audio.open(directory: directory)
    let track = Track(id: UUID(), name: "Meter lifecycle", role: .other)
    var project = Project.empty(name: "Meter lifecycle")
    project.songs[0].tracks = [track]
    var state = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id,
        position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    var amplitude: Float = 0.4
    let source = AVAudioSourceNode(format: outputFormat) { silent, _, frames, buffers in
        silent.pointee = ObjCBool(amplitude == 0)
        for (channel, buffer) in UnsafeMutableAudioBufferListPointer(buffers).enumerated() {
            buffer.mData!.assumingMemoryBound(to: Float.self).update(repeating: amplitude * (channel == 0 ? 1 : 0.5), count: Int(frames))
        }
        return noErr
    }
    audio.setInputMonitor(track.id, source: source, format: outputFormat)
    let level = audio.meter(for: track.id)
    var revision: UInt64 = 1
    try audio.update(state, revision: revision)
    try meterEngine.start()
    let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512)!
    func renderBlocks(_ count: Int) throws {
        for _ in 0..<count {
            let status = try meterEngine.renderOffline(512, to: pcm); precondition(status == .success)
        }
    }
    func poll() throws {
        Thread.sleep(forTimeInterval: 0.04)
        try audio.update(state, revision: revision)
    }
    try renderBlocks(8); try poll()
    precondition(abs(level.levels.x - 0.4) < 0.0001 && abs(level.levels.y - 0.2) < 0.0001,
                 "a bus prepared before its meter bank must capture both channels")
    amplitude = 0.9
    try renderBlocks(2) // Leave this larger peak unread when the track is removed.
    state.project.songs[0].tracks = []; revision += 1
    try audio.update(state, revision: revision)
    try renderBlocks(4)
    amplitude = 0
    state.project.songs[0].tracks = [track]; revision += 1
    try audio.update(state, revision: revision)
    try renderBlocks(8); try poll()
    precondition(level.levels.x <= 0.4001 && level.levels.y <= 0.2001,
                 "restoring a silent track must discard peaks from its former meter bank")
    audio.prepareForClosing()
    precondition(level.levels.x == 0 && level.levels.y == 0 && audio.masterMeter.level == 0)
    audio.open(directory: directory)
    try audio.update(state, revision: revision)
    try meterEngine.start()
    try renderBlocks(8); try poll()
    precondition(level.levels.x == 0 && level.levels.y == 0 && audio.masterMeter.level == 0,
                 "closing and rebuilding a silent graph must not republish prior track or Master peaks")
    audio.prepareForClosing()
    print("INLINE_METER_PREPARED_BUS_REMOVE_RESTORE_AND_REBUILD_LIFECYCLE_OK")
}
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
renderer.previewPan(id, pan: -1)
let leftOnly = try peak()
precondition(abs(output.floatChannelData![1][256]) < 0.0001)
renderer.previewMasterMono(true)
let monoMaster = try peak()
precondition(abs(monoMaster - leftOnly * 0.5) < 0.001, "Master mono sums the post-pan channels with headroom")
precondition(abs(output.floatChannelData![0][256] - output.floatChannelData![1][256]) < 0.0001)
renderer.previewMasterMono(false)
let restoredMaster = try peak()
precondition(abs(restoredMaster - leftOnly) < 0.001 && abs(output.floatChannelData![1][256]) < 0.0001)
renderer.previewPan(id, pan: 0)
print("MASTER_POST_FX_MONO_SUM_AND_LIVE_STEREO_RESTORE_PCM_OK")
// Internal envelopes consume the manual snapshot volume exactly once. M/S
// remains on the ordinary mixer callbacks, and leaving restores manual gain.
var loopRule = MultiLoopTrack(id: id, gain: 0.2); loopRule.autoFader = true
snapshot.transport.multiLoop = MultiLoopPlayback(id: UUID(), start: 1, end: 9, amount: 1, gates: true, released: false, tracks: [loopRule])
try renderer.update(snapshot, revision: 1)
let loopQuiet = try peak()
precondition(abs(loopQuiet - mainPeak * 0.2) < 0.001, "multiloop target gain reaches actual PCM")
snapshot.transport.multiLoop?.amount = 0.5; snapshot.transport.multiLoop?.released = true
try renderer.update(snapshot, revision: 1)
let loopRecovering = try peak()
precondition(abs(loopRecovering - mainPeak * 0.6) < 0.001, "release fade restores proportionally without reload")
snapshot.transport.multiLoop?.amount = 1; snapshot.transport.multiLoop?.tracks[0].mute = true
snapshot.project.songs[0].tracks[0].mute = true
renderer.previewMute(id, muted: true)
try renderer.update(snapshot, revision: 1)
let loopMuted = try peak()
precondition(loopMuted < 0.0001, "multiloop mute reaches actual PCM")
snapshot.transport.multiLoop = nil
snapshot.project.songs[0].tracks[0].volume = 1
snapshot.project.songs[0].tracks[0].mute = false
renderer.previewMute(id, muted: false)
try renderer.update(snapshot, revision: 1)
let loopRestored = try peak()
precondition(abs(loopRestored - mainPeak) < 0.001, "leaving multiloop restores gain and mute")
precondition(snapshot.project.songs[0].tracks[0].volume == 1 && !snapshot.project.songs[0].tracks[0].mute, "leaving the loop restores the visible mixer state")
print("MULTILOOP_INTERNAL_GAIN_RELEASE_VISIBLE_MUTE_RESTORE_PCM_OK")
let heldPeak = TrackMeterLevel()
heldPeak.update(peak: 0.99, elapsed: 0.03); precondition(heldPeak.peakHold.decibels == nil)
heldPeak.update(peak: 1, elapsed: 0.03); precondition(heldPeak.peakHold.decibels == 0)
heldPeak.update(peak: pow(10, 3.0 / 20), elapsed: 0.03)
heldPeak.update(peak: 1.1, elapsed: 0.03); precondition(heldPeak.peakHold.decibels == 3)
heldPeak.reset(); precondition(heldPeak.peakHold.decibels == 3, "Stop retains the maximum clip peak")
var automaticMutes: [UUID] = []
renderer.onPeakLimit = { automaticMutes.append($0) }
renderer.observeTrackPeak(id, left: pow(10, 19.99 / 20), right: 0, elapsed: 0.03)
precondition(automaticMutes.isEmpty)
renderer.observeTrackPeak(id, left: 0, right: pow(10, 20.0 / 20), elapsed: 0.03)
precondition(automaticMutes == [id])
let protectionSilence = try peak(); precondition(protectionSilence < 0.0001)
renderer.observeTrackPeak(id, left: 11, right: 11, elapsed: 0.03)
precondition(automaticMutes == [id], "An already-muted track cannot toggle back on")
renderer.onPeakLimit = nil; renderer.previewMute(id, muted: false)
print("TRACK_PEAK_HOLD_MAXIMUM_AND_20_DB_AUTOMUTE_BOTH_CHANNELS_OK")
let missingEngine = AVAudioEngine()
try missingEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
let missingRenderer = StemAudioPlayback(engine: missingEngine, realtime: false)
missingRenderer.open(directory: directory)
missingRenderer.setMissingAudioPaths(["lost.wav"])
var partiallyMissing = project
partiallyMissing.songs[0].tracks[0].clips.append(AudioClip(id: UUID(), name: "Lost", startTime: 0, duration: 10, audioFile: AudioFile(path: "lost.wav")))
let missingSnapshot = ShowSnapshot(project: partiallyMissing, transport: snapshot.transport)
try missingRenderer.update(missingSnapshot, revision: 1)
var remainingAudio: Float = 0
for iteration in 0..<32 {
    if try missingEngine.renderOffline(512, to: output) == .success, iteration > 24 {
        remainingAudio = max(remainingAudio, (0..<Int(output.frameLength)).map { abs(output.floatChannelData![0][$0]) }.max() ?? 0)
    }
}
precondition(remainingAudio > 0.09 && remainingAudio < 0.11, "missing audio must stay silent while present tracks keep playing")
missingRenderer.stop()
print("MISSING_AUDIO_SILENT_OTHER_TRACKS_PLAY_OK")
do {
    let file = try AVAudioFile(forWriting: directory.appendingPathComponent("tempo-tone.wav"), settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441000)!; buffer.frameLength = 441000
    for c in 0..<2 { for i in 0..<441000 { buffer.floatChannelData![c][i] = Float(0.1 * sin(Double(i) * 2 * .pi * 997 / 44100)) } }
    try file.write(from: buffer)
}
// Tempo markers must leave the actual PCM unchanged in Free Grid, including
// when playback starts directly inside a section after a tempo change.
func markerPCM(position: Double, withMarkers: Bool, projectTimebase: ProjectTimebase = .free, markerTimebase: TempoMarkerTimebase = .global, detectedReference: Bool = false) throws -> [Float] {
    let testEngine = AVAudioEngine()
    try testEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: testEngine, realtime: false); audio.open(directory: directory)
    defer { audio.stop() }
    var mapped = project
    mapped.songs[0].timeSettings = ProjectTimeSettings(); mapped.songs[0].timeSettings?.timebase = projectTimebase
    mapped.songs[0].tracks[0].clips[0].audioFile = AudioFile(path: "tempo-tone.wav")
    if withMarkers {
        mapped.songs[0].markers = [TimelineMarker(id: UUID(), name: "TEMPO", position: 2, color: 0x999999, tempoBPM: 180, tempoTimebase: markerTimebase),
                                   TimelineMarker(id: UUID(), name: "TEMPO", position: 5, color: 0x999999, tempoBPM: 90, tempoTimebase: markerTimebase)]
    }
    if detectedReference, mapped.songs[0].markers != nil {
        for index in mapped.songs[0].markers!.indices {
            mapped.songs[0].markers![index].tempoReferenceBPM = mapped.songs[0].markers![index].tempoBPM
        }
    }
    let state = ShowSnapshot(project: mapped, transport: TransportState(playing: true, songId: mapped.songs[0].id, position: position, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(state, revision: 1)
    var samples: [Float] = []
    for iteration in 0..<32 {
        if try testEngine.renderOffline(512, to: output) == .success, iteration > 24 {
            samples += Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        }
    }
    return samples
}
for position in [3.0, 6] {
    let before = try markerPCM(position: position, withMarkers: false)
    let after = try markerPCM(position: position, withMarkers: true)
    precondition(before.count == after.count && !before.isEmpty)
    let difference = zip(before, after).map { abs($0 - $1) }.max() ?? 1
    precondition(difference < 0.00001, "Free Grid preserves PCM after tempo markers: \(difference) at \(position)")
    let detected = try markerPCM(position: position, withMarkers: true, projectTimebase: .relative, detectedReference: true)
    precondition(zip(before, detected).map { abs($0 - $1) }.max()! < 0.00001, "Detected tempo references preserve original PCM in Relative Grid")
    let forcedFree = try markerPCM(position: position, withMarkers: true, projectTimebase: .relative, markerTimebase: .free)
    precondition(zip(before, forcedFree).map { abs($0 - $1) }.max()! < 0.00001, "Free marker overrides Relative Grid playback")
    let inheritedRelative = try markerPCM(position: position, withMarkers: true, projectTimebase: .relative)
    let forcedRelative = try markerPCM(position: position, withMarkers: true, markerTimebase: .relative)
    precondition(inheritedRelative.count == forcedRelative.count && !inheritedRelative.isEmpty)
    precondition(zip(inheritedRelative, forcedRelative).map { abs($0 - $1) }.max()! < 0.00001, "Relative marker overrides Free Grid playback")
}
print("GLOBAL_FREE_AND_RELATIVE_MARKER_TIMEBASE_PCM_OK")
// Item gain must reach +24 dB in actual PCM, including temporary tempo fragments.
for position in [0.0, 3, 6] {
    let testEngine = AVAudioEngine()
    try testEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: testEngine, realtime: false); audio.open(directory: directory)
    var mapped = project
    mapped.songs[0].timeSettings = ProjectTimeSettings(); mapped.songs[0].timeSettings?.timebase = .relative
    mapped.songs[0].tracks[0].volume = 0.1
    mapped.songs[0].tracks[0].clips[0].audioFile = AudioFile(path: "tempo-tone.wav")
    mapped.songs[0].markers = [TimelineMarker(id: UUID(), name: "TEMPO", position: 2, color: 0x999999, tempoBPM: 180),
                               TimelineMarker(id: UUID(), name: "TEMPO", position: 5, color: 0x999999, tempoBPM: 90)]
    let state = ShowSnapshot(project: mapped, transport: TransportState(playing: true, songId: mapped.songs[0].id, position: position, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(state, revision: 1)
    audio.previewItemGain(track.clips[0].id, gain: pow(10,24.0/20))
    var value: Float = 0
    for iteration in 0..<32 {
        if try testEngine.renderOffline(512, to: output) == .success, iteration > 24 {
            value = max(value, (0..<Int(output.frameLength)).map { abs(output.floatChannelData![0][$0]) }.max() ?? 0)
        }
    }
    precondition(abs(value - Float(0.01 * pow(10,24.0/20))) < 0.01, "selected original item gain reaches +24 dB on every tempo fragment: \(value) at \(position)")
    audio.previewClipMute(track.clips[0].id, muted: true)
    var silent: Float = 0
    for iteration in 0..<32 {
        if try testEngine.renderOffline(512, to: output) == .success, iteration > 24 {
            silent = max(silent, (0..<Int(output.frameLength)).map { abs(output.floatChannelData![0][$0]) }.max() ?? 0)
        }
    }
    precondition(silent < 0.0001, "original item mute silences every tempo fragment")
    audio.stop()
}
print("ITEM_PLUS24_DB_TEMPO_FRAGMENT_PCM_AND_ORIGINAL_ITEM_MUTE_OK")
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
snapshot.project.songs[0].timeSettings = ProjectTimeSettings()
snapshot.project.songs[0].timeSettings?.timebase = .relative
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
func renderTempo(_ rate: Double, change: Bool = false, timebase: ProjectTimebase = .relative) throws -> [[Float]] {
    renderer.open(directory: directory)
    var project = Project.empty(name: "Tempo PCM")
    project.songs[0].timeSettings = ProjectTimeSettings()
    project.songs[0].timeSettings?.timebase = timebase
    var track = Track(id: UUID(), name: "Tempo", role: .other)
    track.clips = [AudioClip(id: UUID(), name: "Stereo", startTime: 0, duration: 4, audioFile: AudioFile(path: "tempo.wav"))]
    project.songs[0].tracks = [track]
    project.songs[0].followTempo(120 * (change ? 1 : rate))
    var state = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    var revision: UInt64 = 200
    var samples = [[Float](), [Float]()]
    var changed = false
    let total = Int(outputFormat.sampleRate * (change ? 3 : 3 / (timebase == .relative ? rate : 1) + 0.4))
    var position = 0.0
    while samples[0].count < total {
        if change && !changed && samples[0].count >= Int(outputFormat.sampleRate) {
            state.project.songs[0].followTempo(120 * rate)
            if timebase == .relative { position /= rate; revision += 1 }
            changed = true
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
let unchangedFreePCM = try renderTempo(1, change: true, timebase: .free)
let changedFreePCM = try renderTempo(1.5, change: true, timebase: .free)
for channel in 0..<2 {
    precondition(unchangedFreePCM[channel].count == changedFreePCM[channel].count)
    precondition(zip(unchangedFreePCM[channel], changedFreePCM[channel]).map { abs($0 - $1) }.max()! < 0.00001, "Free Grid BPM edits keep playing PCM uninterrupted")
}
print("FREE_GRID_BPM_EDIT_PRESERVES_RUNNING_PCM_OK")

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
routingState.project.masterSolo = true
try checkRoutes([0.05,0.05,0,0,0,0], "Master solo preserves the group path and suppresses its parallel direct hardware send")
routingState.project.masterSolo = false
try checkRoutes([0.05,0.05,0.1,0.1,0,0], "clearing Master solo restores the original hardware routing")
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
var importedSpanSettings = TimecodeSettings()
importedSpanSettings.mode = "mtc"; importedSpanSettings.frameRate = 25; importedSpanSettings.offset = 3602
var importedSpanTrack = spanTrack
importedSpanTrack.clips[0].id = UUID()
importedSpanTrack.clips[0].timecode = importedSpanSettings
let importedSpan = TimecodePlaybackSpan(song: spanProject.songs[0], track: importedSpanTrack, position: 1.3, settings: spanSettings, preferredRegion: nil)!
precondition(abs(importedSpan.time - 3602.8) < 0.000001 && importedSpan.end == 3604, "imported generator uses its own item origin and clock settings")
var spanState = ShowSnapshot(project: spanProject, transport: TransportState(playing: true, songId: spanProject.songs[0].id, position: 0.3, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
let spanBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512)!
func timecodeSpanPeak(at position: Double, revision: UInt64, warmup: Int = 0) throws -> Float {
    spanState.transport.position = position
    try spanAudio.update(spanState, revision: revision)
    var peak: Float = 0
    for block in 0..<(warmup + 4) {
        let status = try spanEngine.renderOffline(512, to: spanBuffer)
        precondition(status == .success)
        if block >= warmup { for sample in 0..<Int(spanBuffer.frameLength) { peak = max(peak, abs(spanBuffer.floatChannelData![0][sample])) } }
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
var timecodeRule = MultiLoopTrack(id: spanTrack.id, gain: 0.2); timecodeRule.autoFader = true
var timecodeMasterRule = MultiLoopTrack(id: MultiLoopTrack.masterID, gain: 0); timecodeMasterRule.autoFader = true
spanState.transport.multiLoop = MultiLoopPlayback(id: UUID(), start: 0.5, end: 2.5, amount: 0.5,
    gates: true, released: false, tracks: [timecodeRule, timecodeMasterRule])
// LTC retains its existing 10 ms gain smoothing. Exclude the transition when
// checking the settled amplitude; the PCM reference above checks transitions.
let fadedTimecode = try timecodeSpanPeak(at: 1.3, revision: 1, warmup: 16)
precondition(abs(fadedTimecode - rightSpanPCM * 0.6) < 0.00001, "LTC consumes one envelope on its direct hardware route: original=\(rightSpanPCM) faded=\(fadedTimecode) manual=\(spanTrack.volume)")
spanAudio.previewVolume(spanTrack.id, gain: 0.8); spanAudio.previewPhase(spanTrack.id, inverted: true)
let manualTimecode = try timecodeSpanPeak(at: 1.3, revision: 1, warmup: 16)
precondition(abs(manualTimecode - rightSpanPCM * 0.5) < 0.00001, "LTC manual preview retains the active envelope")
spanState.project.songs[0].tracks[0].volume = 0.8
spanState.transport.multiLoop?.amount = 1
let timecodeWithSilentMaster = try timecodeSpanPeak(at: 1.3, revision: 1, warmup: 16)
precondition(abs(timecodeWithSilentMaster - rightSpanPCM * 0.2) < 0.00001, "Master Auto Fader zero cannot gate the independent LTC route")
spanState.transport.multiLoop = nil; spanState.project.songs[0].tracks[0].volume = 1
spanAudio.previewVolume(spanTrack.id, gain: 1)
let restoredTimecode = try timecodeSpanPeak(at: 1.3, revision: 1, warmup: 16)
precondition(abs(restoredTimecode - rightSpanPCM) < 0.00001, "LTC restores manual gain when the loop ends")
print("INTERNAL_AUTOFADER_TIMECODE_SINGLE_GAIN_PREVIEW_PHASE_DIRECT_MASTER_BYPASS_OK")
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
spanState.project.songs[0].tracks[0].clips[0].timecode = importedSpanSettings
let importedMTCPeak = try timecodeSpanPeak(at: 1.3, revision: 5)
precondition(importedMTCPeak < 0.000001, "per-item MTC overrides LTC track mode without sending LTC audio")
spanState.project.songs[0].tracks[0].clips[0].timecode?.mode = "ltc"
let importedLTCPeak = try timecodeSpanPeak(at: 1.3, revision: 6)
precondition(importedLTCPeak > 0.2, "per-item LTC is regenerated natively")
spanState.project.songs[0].tracks[0].clips[0].muted = true
let importedMutedPeak = try timecodeSpanPeak(at: 1.3, revision: 7)
precondition(importedMutedPeak < 0.000001, "muted imported generator emits no timecode")
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
scalarAudio.previewMasterSolo(true); try scalarCheck(0, "Master solo suppresses hardware bypass even when Master is muted")
scalarAudio.previewMasterSolo(false); try scalarCheck(0.1, "clearing Master solo restores the active direct output without restarting players")
scalarAudio.previewPatch(childA.id, patch: .master, slot: 1); try scalarCheck(0.1, "second send preserves direct output")
scalarAudio.previewMute(nil, muted: false); try scalarCheck(0.3, "both sends coexist without rescheduling players")
scalarAudio.previewMasterSolo(true); try scalarCheck(0.2, "Master solo preserves all Master sends while silencing their direct duplicates")
scalarAudio.previewPatch(childA.id, patch: .stereo, slot: 1); try scalarCheck(0.1, "routing changes during Master solo cannot leak a hardware-only track")
scalarAudio.previewPatch(childA.id, patch: .master, slot: 1); try scalarCheck(0.2, "a track newly routed to Master becomes audible while solo stays active")
scalarAudio.previewMasterSolo(false); try scalarCheck(0.3, "Master solo leaves gains, individual solos and both heads unchanged")
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
JarasChannelRouter.configurePatches(matrix, firsts: [1], counts: [2])
for _ in 0..<16 { let status = try routeEngine.renderOffline(512, to: routeBuffer); precondition(status == .success) }
let beforeStop = routeBuffer.floatChannelData![0][511]
precondition(beforeStop > 0.19)
JarasChannelRouter.setRenderEnabled(matrix, enabled: false)
let stoppingStatus = try routeEngine.renderOffline(512, to: routeBuffer)
precondition(stoppingStatus == .success)
let stopSamples = routeBuffer.floatChannelData![0]
precondition(stopSamples[0] > 0.18 && stopSamples[32] < stopSamples[0] && stopSamples[32] > 0,
             "Stop should fade rather than disconnect at a nonzero sample")
precondition(abs(stopSamples[400]) < 0.000001, "Stop fade must end in silence within one output buffer")
let stoppedStatus = try routeEngine.renderOffline(512, to: routeBuffer)
precondition(stoppedStatus == .success)
precondition(abs(routeBuffer.floatChannelData![0][0]) < 0.000001)
JarasChannelRouter.setRenderEnabled(matrix, enabled: true)
for _ in 0..<16 { let status = try routeEngine.renderOffline(512, to: routeBuffer); precondition(status == .success) }
precondition(abs(routeBuffer.floatChannelData![0][400] - 0.2) < 0.001, "Play restores routed audio after Stop")
JarasChannelRouter.beginStopFade(matrix)
let armedStopStatus = try routeEngine.renderOffline(512, to: routeBuffer)
precondition(armedStopStatus == .success)
precondition(routeBuffer.floatChannelData![0][0] > 0.18 && abs(routeBuffer.floatChannelData![0][400]) < 0.000001,
             "Stop fades routed audio even while the graph remains awake for armed instruments")
routeEngine.stop()
print("DYNAMIC_HARDWARE_STEREO_MONO_DUPLICATE_SUPPRESSION_AND_REMOVAL_PCM_OK")
print("STOP_OUTPUT_SHORT_FADE_AND_RESTART_OK")
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
var repeated = NativeFXSettings()
let compressorOne = repeated.appendNative("Compressor")
let compressorTwo = repeated.appendNative("Compressor")
repeated.threshold = 0; repeated.ratio = 1; repeated.makeup = 6
var secondCompressor = repeated.settings(for: compressorTwo)
secondCompressor.threshold = 0; secondCompressor.ratio = 1; secondCompressor.makeup = 6
repeated = repeated.merging(effect: compressorTwo, from: secondCompressor)
orderedAudio.previewFX(nil, settings: NativeFXSettings())
orderedAudio.previewFX(orderedTrack.id, settings: repeated)
func repeatedPeak(_ expected: Float) throws {
    for _ in 0..<32 { let status = try orderedEngine.renderOffline(512, to: orderedBuffer); precondition(status == .success) }
    let sample = orderedBuffer.floatChannelData![0][128]
    precondition(abs(sample - expected) < 0.01, "independent repeated processors must both process PCM: \(sample) vs \(expected)")
}
try repeatedPeak(0.2 * Float(pow(10, 12.0 / 20)))
repeated.setEnabled(compressorOne, enabled: false)
orderedAudio.previewFX(orderedTrack.id, settings: repeated)
try repeatedPeak(0.2 * Float(pow(10, 6.0 / 20)))
repeated.inserted.reverse()
orderedAudio.previewFX(orderedTrack.id, settings: repeated)
try repeatedPeak(0.2 * Float(pow(10, 6.0 / 20)))
repeated.inserted.removeAll { $0 == compressorTwo }; repeated.removeInstance(compressorTwo)
orderedAudio.previewFX(orderedTrack.id, settings: repeated)
try repeatedPeak(0.2)
precondition(orderedEngine.attachedNodes.count == orderedNodes, "removing repeated processors releases their audio nodes")
print("REPEATED_NATIVE_PROCESSORS_INDEPENDENT_GAIN_BYPASS_REORDER_REMOVE_PCM_OK")
let normalizedClip = orderedTrack.clips[0].id
orderedAudio.previewItemNormalization(normalizedClip, gain: 0.5)
try repeatedPeak(0.1)
orderedAudio.previewItemGain(normalizedClip, gain: 0.5)
try repeatedPeak(0.05)
orderedAudio.previewItemNormalization(normalizedClip, gain: 1)
try repeatedPeak(0.1)
orderedAudio.previewItemGain(normalizedClip, gain: 1)
try repeatedPeak(0.2)
print("NORMALIZATION_AND_ITEM_VOLUME_INDEPENDENT_LIVE_PCM_OK")
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
pitchState.project.songs[0].tracks[0].clips[0].pitchSemitones = 12
try pitchAudio.update(pitchState, revision: 3); try expectFrequency(880)
pitchState.project.songs[0].tracks[0].clips[0].renderedTiming = true
pitchState.project.songs[0].tracks[0].clips[0].pitchSemitones = -12
try pitchAudio.update(pitchState, revision: 4); try expectFrequency(220)
pitchState.project.songs[0].tracks[0].clips[0].pitchSemitones = nil
try pitchAudio.update(pitchState, revision: 5); try expectFrequency(440)
print("ITEM_TUNER_LIVE_AND_PRINTED_AUDIO_PITCH_OK")
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


let previousVideoNoAudio = VideoMediaSettings.shared.noAudio
VideoMediaSettings.shared.noAudio = false
let videoFolder = directory.appendingPathComponent("Videos")
try FileManager.default.createDirectory(at: videoFolder, withIntermediateDirectories: true)
try FileManager.default.copyItem(at: directory.appendingPathComponent("tone.wav"), to: videoFolder.appendingPathComponent("soundtrack.wav"))
var videoProject = Project.empty(name: "Video audio")
let videoID = UUID()
var videoTrack = Track(id: videoID, name: "Video", role: TrackRole(rawValue: "video"), volume: 0.5, pan: 0, mute: false, solo: true)
videoTrack.clips = [AudioClip(id: UUID(), name: "Video", startTime: 0, duration: 2, audioFile: AudioFile(path: "Videos/soundtrack.wav"))]
videoProject.songs[0].tracks = [videoTrack]; videoProject.songs[0].duration = 2
try videoProject.validate()
let videoEngine = AVAudioEngine()
try videoEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
let videoAudio = StemAudioPlayback(engine: videoEngine, realtime: false)
videoAudio.open(directory: directory)
var videoSnapshot = ShowSnapshot(project: videoProject, transport: TransportState(playing: true, songId: videoProject.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
try videoAudio.update(videoSnapshot, revision: 1)
try videoEngine.start()
let videoBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512)!
func videoPeak() throws -> Float {
    for _ in 0..<40 { _ = try videoEngine.renderOffline(512, to: videoBuffer) }
    return (0..<512).map { abs(videoBuffer.floatChannelData![0][$0]) }.max()!
}
precondition(abs(try! videoPeak() - 0.05) < 0.003, "video soundtrack passes through its track fader")
videoAudio.previewVolume(videoID, gain: 0.25)
precondition(abs(try! videoPeak() - 0.025) < 0.003)
videoAudio.previewMute(videoID, muted: true)
precondition(try! videoPeak() < 0.00001)
videoAudio.previewMute(videoID, muted: false)
precondition(abs(try! videoPeak() - 0.025) < 0.003)
VideoMediaSettings.shared.noAudio = true
try videoAudio.update(videoSnapshot, revision: 1)
precondition(try! videoPeak() < 0.00001, "No audio silences only video voices without stopping transport")
VideoMediaSettings.shared.noAudio = false
try videoAudio.update(videoSnapshot, revision: 1)
precondition(abs(try! videoPeak() - 0.05) < 0.003, "unchecking No audio resumes the soundtrack")
videoAudio.prepareForClosing()
VideoMediaSettings.shared.noAudio = previousVideoNoAudio
print("VIDEO_AUDIO_FADER_MUTE_SOLO_AND_LIVE_NO_AUDIO_ROUTING_PCM_OK")

print("REAL_AUDIO_RENDER_OK main=\(mainPeak) +12dB=\(louder) muted=\(muted)")

// Stereo track meters must observe the actual PCM after pan and gain, even
// when Master is muted or this track routes directly to hardware.
for panValue in [-1.0, -0.75, -0.5, -0.25, 0.0, 0.25, 0.5, 0.75, 1.0] {
    let panEngine = AVAudioEngine()
    try panEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
    let panRenderer = StemAudioPlayback(engine: panEngine, realtime: false)
    panRenderer.open(directory: directory)
    var panProject = Project.empty(name: "Pan meter")
    var panTrack = track
    panTrack.pan = panValue; panTrack.volume = 0.5
    panTrack.patch = OutputPatch(firstChannel: 1, channelCount: 2)
    panProject.songs[0].tracks = [panTrack]; panProject.masterMute = true
    let panState = ShowSnapshot(project: panProject, transport: TransportState(playing: true,songId: panProject.songs[0].id,position: 0,queue: QueueState(),loop: LoopState(enabled: false),subPlay: SubPlayState(playing: false,position: 0)))
    let level = panRenderer.meter(for: panTrack.id)
    try panRenderer.update(panState, revision: 1)
    let panBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,frameCapacity: 512)!
    var pcm = SIMD2<Double>(repeating: 0)
    for block in 0..<48 {
        let status = try panEngine.renderOffline(512,to: panBuffer)
        precondition(status == .success)
        if block > 24 {
            for channel in 0..<2 { for frame in 0..<Int(panBuffer.frameLength) {
                pcm[channel] = max(pcm[channel],Double(abs(panBuffer.floatChannelData![channel][frame])))
            } }
        }
    }
    Thread.sleep(forTimeInterval: 0.06)
    try panRenderer.update(panState, revision: 1)
    precondition(abs(level.levels.x - pcm.x) < 0.005 && abs(level.levels.y - pcm.y) < 0.005,
                 "track meter must match post-pan PCM independently of Master: pan=\(panValue), meter=\(level.levels), pcm=\(pcm)")
    let expected = SIMD2(0.05 * (1 - max(0, panValue)), 0.05 * (1 + min(0, panValue)))
    precondition(abs(pcm.x - expected.x) < 0.0001 && abs(pcm.y - expected.y) < 0.0001,
                 "fractional stereo balance preserves the original Apple mixer curve: pan=\(panValue), pcm=\(pcm)")
    if panValue == -1 { precondition(pcm.x > 0.02 && pcm.y < 0.00001) }
    if panValue == 1 { precondition(pcm.y > 0.02 && pcm.x < 0.00001) }
    if panValue == 0 { precondition(pcm.x > 0.02 && pcm.y > 0.02) }
    panRenderer.stop()
}
print("TRACK_STEREO_METERS_MATCH_POST_PAN_GAIN_PCM_WITH_MUTED_MASTER_OK")

if let path = ProcessInfo.processInfo.environment["JARAS_TEST_SF2"] {
    let instrumentEngine = AVAudioEngine()
    try instrumentEngine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
    let instrumentAudio = StemAudioPlayback(engine: instrumentEngine, realtime: false)
    instrumentAudio.open(directory: directory)
    instrumentAudio.instrumentFile = { _ in (URL(fileURLWithPath: path), true) }
    var instrumentProject = Project.empty(name: "Repeated SF2")
    var instrumentFX = NativeFXSettings()
    let sfOne = instrumentFX.appendNative("Instruments", instrument: "glide-moog", parameters: InstrumentParameters())
    let sfTwo = instrumentFX.appendNative("Instruments", instrument: "glide-moog", parameters: InstrumentParameters())
    var instrumentTrack = Track(id: UUID(), name: "Layer", role: .keys); instrumentTrack.fx = instrumentFX
    instrumentProject.songs[0].tracks = [instrumentTrack]
    instrumentAudio.setArmedInstrumentTracks([instrumentTrack.id])
    let state = ShowSnapshot(project: instrumentProject, transport: TransportState(playing: false, songId: instrumentProject.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try instrumentAudio.update(state, revision: 1)
    let deadline = Date().addingTimeInterval(20)
    while !instrumentAudio.isInstrumentReady(instrumentTrack.id) && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    precondition(instrumentAudio.isInstrumentReady(instrumentTrack.id), "both independent SF2 instances finish loading")
    let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512)!
    func instrumentPeak() throws -> Float {
        var peak: Float = 0
        for _ in 0..<32 {
            let status = try instrumentEngine.renderOffline(512, to: buffer); precondition(status == .success)
            for c in 0..<2 { for f in 0..<Int(buffer.frameLength) { peak = max(peak, abs(buffer.floatChannelData![c][f])) } }
        }
        return peak
    }
    for active in [sfOne, sfTwo] {
        instrumentAudio.releaseMIDINotes()
        instrumentFX.setEnabled(sfOne, enabled: active == sfOne)
        instrumentFX.setEnabled(sfTwo, enabled: active == sfTwo)
        instrumentAudio.previewFX(instrumentTrack.id, settings: instrumentFX)
        _ = try instrumentPeak() // Render the pending all-notes-off before sending the next note.
        instrumentAudio.playKeyboardNote(60)
        let peak = try instrumentPeak()
        precondition(peak > 0.0001, "each repeated SF2 receives notes independently: \(active), peak=\(peak)")
    }
    instrumentAudio.releaseMIDINotes(); _ = try instrumentPeak()
    instrumentAudio.midiSlotsProvider = { [Int32(123), 0, 0] }
    instrumentAudio.previewMIDIInput(instrumentTrack.id, slot: 1)
    instrumentAudio.previewMIDIChannel(instrumentTrack.id, channel: 2)
    _ = try instrumentPeak()
    instrumentAudio.receiveMIDI(device: 123, status: 0x90, number: 60, value: 100)
    let wrongChannel = try instrumentPeak()
    precondition(wrongChannel < 0.00001, "SF2 ignores notes on other channels")
    instrumentAudio.receiveMIDI(device: 123, status: 0x91, number: 60, value: 100)
    let rightChannel = try instrumentPeak()
    precondition(rightChannel > 0.0001, "SF2 plays the selected MIDI channel")
    instrumentAudio.previewMIDIChannel(instrumentTrack.id, channel: 3)
    _ = try instrumentPeak()
    let releasedChannel = try instrumentPeak()
    precondition(releasedChannel < 0.00001, "changing MIDI channel releases former notes")
    instrumentAudio.receiveMIDI(device: 123, status: 0x92, number: 60, value: 100)
    let newChannel = try instrumentPeak()
    precondition(newChannel > 0.0001, "new MIDI channel plays without rebuilding the engine")
    print("MIDI_CHANNEL_FILTER_AND_LIVE_CHANNEL_CHANGE_PCM_OK")
    var mutedInstrument = instrumentFX.settings(for: sfTwo)
    var parameters = mutedInstrument.instrumentParameters ?? InstrumentParameters()
    parameters.controllers = InstrumentControllerParameters()
    parameters.controllers?.volume = -96
    mutedInstrument.instrumentParameters = parameters
    instrumentFX = instrumentFX.merging(effect: sfTwo, from: mutedInstrument)
    instrumentAudio.previewFX(instrumentTrack.id, settings: instrumentFX)
    _ = try instrumentPeak()
    let quiet = try instrumentPeak()
    precondition(quiet < 0.00001, "Controller volume silences only its own instrument")
    instrumentAudio.prepareForClosing()
    print("REPEATED_SF2_INDEPENDENT_MIDI_BYPASS_AND_CONTROLLER_VOLUME_PCM_OK")
}

// Live input uses the same track graph while stored clips stay independent.
for route in [0, 1, 2] {
    let liveEngine = AVAudioEngine()
    let liveFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!)
    try liveEngine.enableManualRenderingMode(.offline, format: liveFormat, maximumFrameCount: 512)
    let liveAudio = StemAudioPlayback(engine: liveEngine, realtime: false)
    liveAudio.open(directory: directory)
    var p = Project.empty(name: "Live monitoring")
    var inputTrack = Track(id: UUID(), name: "Input", role: .other)
    inputTrack.volume = 0.5
    var destination = Track(id: UUID(), name: "Bus", role: .other)
    if route == 1 { inputTrack.outputs = [OutputPatch(firstChannel: 3, channelCount: 2)] }
    if route == 2 { inputTrack.parentTrackID = destination.id; destination.volume = 0.5 }
    p.songs[0].tracks = route == 2 ? [destination, inputTrack] : [inputTrack]
    var state = ShowSnapshot(project: p, transport: TransportState(playing: true, songId: p.songs[0].id, position: 0,
        queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try liveAudio.update(state, revision: 1)
    let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let source = AVAudioSourceNode(format: sourceFormat) { silent, _, frames, buffers in
        silent.pointee = false
        for (channel, buffer) in UnsafeMutableAudioBufferListPointer(buffers).enumerated() {
            buffer.mData!.assumingMemoryBound(to: Float.self).update(repeating: channel == 0 ? 0.2 : 0.4, count: Int(frames))
        }
        return noErr
    }
    liveAudio.setInputMonitor(inputTrack.id, source: source, format: sourceFormat)
    let pcm = AVAudioPCMBuffer(pcmFormat: liveFormat, frameCapacity: 512)!
    func livePeaks() throws -> [Float] {
        var peaks = [Float](repeating: 0, count: 4)
        for _ in 0..<48 {
            let rendered = try liveEngine.renderOffline(512, to: pcm); precondition(rendered == .success)
            for c in 0..<4 { for f in 0..<512 { peaks[c] = max(peaks[c], abs(pcm.floatChannelData![c][f])) } }
        }
        return peaks
    }
    let on = try livePeaks(), first = route == 1 ? 2 : 0
    precondition(on[first] > 0.01 && on[first+1] > on[first], "monitor follows stereo channels through Master, group or hardware route")
    if route == 1 { precondition(on[0] < 0.00001 && on[1] < 0.00001, "direct monitoring does not leak to Master") }
    let i = state.project.songs[0].tracks.firstIndex { $0.id == inputTrack.id }!
    state.project.songs[0].tracks[i].inputMonitoring = false
    try liveAudio.update(state, revision: 2)
    _ = try livePeaks()
    let off = try livePeaks(); precondition(off.max()! < 0.00001, "Monitor Off silences the attached live input through the actual setting")
    precondition(liveAudio.hasInputMonitor(inputTrack.id), "Monitor Off keeps the capture route attached")
    state.project.songs[0].tracks[i].inputMonitoring = true
    try liveAudio.update(state, revision: 3)
    let resumed = try livePeaks()
    precondition(resumed[first] > 0.01, "Monitor On resumes the same source without rearming")
    state.project.songs[0].tracks[i].inputMonitoring = false
    try liveAudio.update(state, revision: 4)
    _ = try livePeaks()
    let offAgain = try livePeaks(); precondition(offAgain.max()! < 0.00001, "Monitor Off works repeatedly during playback")
    state.project.songs[0].tracks[i].clips = [AudioClip(id: UUID(), name: "Recorded", startTime: 0, duration: 5, audioFile: AudioFile(path: "tone.wav"))]
    try liveAudio.update(state, revision: 5)
    let recorded = try livePeaks(); print("MONITOR_RECORDED_PCM", route, recorded); precondition(recorded[first] > 0.001, "Monitor Off never silences recorded clips")
    var captured: [UInt8] = []
    liveAudio.armedMIDIRecordingTracks = [inputTrack.id]
    liveAudio.onLiveKeyboardMIDI = { _, status, _, _ in captured.append(status) }
    liveAudio.playKeyboardNote(60); liveAudio.releaseKeyboardNote(60)
    precondition(captured == [0x90, 0x80], "virtual keyboard records MIDI on tracks without an instrument")
    liveAudio.prepareForClosing()
}
print("INPUT_MONITOR_MASTER_GROUP_HARDWARE_OFF_RECORDED_AUDIO_AND_MIDI_CAPTURE_OK")

// Folder inside folder: every gain stage is audible, and child Solo keeps the
// complete path alive without admitting siblings outside the selected subtree.
do {
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: engine, realtime: false)
    audio.open(directory: directory)
    var p = Project.empty(name: "Nested folders PCM")
    var outer = Track(id: UUID(), name: "Outer", role: .keys); outer.volume = 0.5
    var inner = Track(id: UUID(), name: "Inner", role: .keys); inner.volume = 0.5; inner.parentTrackID = outer.id
    let leaf = scalarTrack("Leaf", volume: 1, parent: inner.id)
    let sibling = scalarTrack("Sibling", volume: 1, parent: outer.id)
    p.songs[0].tracks = [outer, inner, leaf, sibling]
    try p.validate()
    let snapshot = ShowSnapshot(project: p, transport: TransportState(playing: true, songId: p.songs[0].id, position: 0,
        queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(snapshot, revision: 1)
    let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512)!
    func check(_ expected: Float) throws {
        var peak: Float = 0
        for block in 0..<16 {
            let status = try engine.renderOffline(512, to: pcm)
            precondition(status == .success)
            if block > 8 { for frame in 0..<512 { peak = max(peak, abs(pcm.floatChannelData![0][frame])) } }
        }
        precondition(abs(peak - expected) < 0.002, "Nested chain PCM: expected \(expected), got \(peak)")
    }
    try check(0.075)
    audio.previewSolo(leaf.id, solo: true); try check(0.025)
    audio.previewSolo(leaf.id, solo: false)
    audio.previewSolo(inner.id, solo: true); try check(0.025)
    audio.previewMute(outer.id, muted: true); try check(0)
    audio.previewMute(outer.id, muted: false)
    audio.previewVolume(inner.id, gain: 0.25); try check(0.0125)
    audio.prepareForClosing()
    print("NESTED_FOLDER_PARENT_GAIN_CHILD_AND_FOLDER_SOLO_MUTE_PCM_OK")
}


}
try MainActor.assumeIsolated { try run() }
