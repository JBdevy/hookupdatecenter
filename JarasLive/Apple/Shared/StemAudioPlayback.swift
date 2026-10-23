import AVFoundation
import Accelerate
import SwiftUI

@MainActor final class MetronomeSettings: ObservableObject {
    static let shared = MetronomeSettings()
    @Published var enabled = UserDefaults.standard.bool(forKey: "jaras.metronome.enabled") { didSet { persist("enabled", enabled) } }
    @Published var preset = UserDefaults.standard.string(forKey: "jaras.metronome.preset") ?? "Digital" { didSet { soundRevision &+= 1; persist("preset", preset) } }
    @Published var mode = UserDefaults.standard.integer(forKey: "jaras.metronome.mode") { didSet { soundRevision &+= 1; persist("mode", mode) } }
    @Published var gainA = (UserDefaults.standard.object(forKey: "jaras.metronome.gainA") as? NSNumber)?.doubleValue ?? -1.0 { didSet { persist("gainA", gainA) } }
    @Published var gainB = (UserDefaults.standard.object(forKey: "jaras.metronome.gainB") as? NSNumber)?.doubleValue ?? -1.0 { didSet { persist("gainB", gainB) } }
    @Published var output: OutputPatch = {
        guard let data = UserDefaults.standard.data(forKey: "jaras.metronome.output"),
              let patch = try? JSONDecoder().decode(OutputPatch.self, from: data),
              (try? patch.validate(allowMaster: false)) != nil else { return .stereo }
        return patch
    }() { didSet {
        if output != oldValue, let data = try? JSONEncoder().encode(output) { persist("output", data) }
    } }
    @Published private(set) var pathA = UserDefaults.standard.string(forKey: "jaras.metronome.pathA") ?? ""
    @Published private(set) var pathB = UserDefaults.standard.string(forKey: "jaras.metronome.pathB") ?? ""
    @Published var error = ""
    private(set) var soundRevision: UInt64 = 0
    var changed: (() -> Void)?
    private func persist(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: "jaras.metronome." + key); changed?() }
    func importSound(_ url: URL, a: Bool) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            _ = try AVAudioFile(forReading: url)
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Jaras Live/Metronome")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: destination)
            if a { pathA = destination.path } else { pathB = destination.path }
            soundRevision &+= 1; error = ""; persist(a ? "pathA" : "pathB", destination.path)
        } catch { self.error = error.localizedDescription }
    }
    func sounds(sampleRate: Double) throws -> (Data, Data) {
        func pcm(_ values: [Float]) -> Data { values.withUnsafeBytes { Data($0) } }
        func custom(_ path: String) throws -> Data {
            guard !path.isEmpty else { return Data() }
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            guard file.length > 0, file.length < AVAudioFramePosition(UInt32.max),
                  let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                  let converter = AVAudioConverter(from: file.processingFormat, to: format),
                  let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(file.length) * sampleRate / file.processingFormat.sampleRate)) + 256) else { throw ProjectError.invalid("Unable to load click audio") }
            try file.read(into: input)
            converter.downmix = true
            var supplied = false; var failure: NSError?
            let result = converter.convert(to: output, error: &failure) { _, status in
                if supplied { status.pointee = .endOfStream; return nil }
                supplied = true; status.pointee = .haveData; return input
            }
            if let failure { throw failure }
            guard result != .error, let samples = output.floatChannelData?[0] else { throw ProjectError.invalid("Unable to load click audio") }
            return Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Float>.size)
        }
        if preset == "User" { return try (custom(pathA), custom(pathB)) }
        func tone(_ accent: Bool) -> Data {
            let length = Int(sampleRate * 0.035)
            let hz = preset == "Wood" ? (accent ? 1000.0 : 700.0) : preset == "Clave" ? (accent ? 2200.0 : 1700.0) : (accent ? 1600.0 : 1000.0)
            let samples: [Float] = (0..<length).map { index in
                let t = Double(index) / sampleRate
                let envelope = min(1, t / 0.0008) * pow(max(0, 1 - t / 0.035), 4)
                let fundamental = sin(2 * Double.pi * hz * t)
                let harmonic = preset == "Digital" ? 0 : sin(2 * Double.pi * hz * 1.67 * t) * (preset == "Wood" ? 0.6 : 0.3)
                return Float((fundamental + harmonic) * envelope)
            }
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            return pcm(peak > 0 ? samples.map { $0 / peak } : samples)
        }
        return (tone(true), tone(false))
    }
}

@MainActor final class TrackMIDIActivity: ObservableObject {
    @Published private(set) var level = 0.0
    private var release: Task<Void, Never>?
    func pulse(_ velocity: UInt8) {
        release?.cancel(); level = max(0.2, Double(velocity) / 127)
        release = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            withAnimation(.easeOut(duration: 0.12)) { self?.level = 0 }
        }
    }
    func reset() { release?.cancel(); release = nil; level = 0 }
}
@MainActor final class InstrumentKeyboardState: ObservableObject {
    static let shared = InstrumentKeyboardState()
    @Published private(set) var notes: Set<UInt8> = []
    private var held: [UUID: [Int64: UInt8]] = [:]
    private var activities: [UUID: TrackMIDIActivity] = [:]
    func activity(_ id: UUID) -> TrackMIDIActivity {
        if let state = activities[id] { return state }
        let state = TrackMIDIActivity(); activities[id] = state; return state
    }
    func receive(track: UUID, source: Int32, status: UInt8, number: UInt8, value: UInt8) {
        let kind = status & 0xf0
        let channel = Int64(status & 0x0f)
        let key = (Int64(source) << 12) | (channel << 8) | Int64(number)
        if kind == 0x90 && value > 0 {
            held[track, default: [:]][key] = number; activity(track).pulse(value)
        } else if kind == 0x80 || (kind == 0x90 && value == 0) { held[track]?[key] = nil }
        else if kind == 0xb0 && [120,123].contains(number) {
            held[track] = held[track]?.filter { ($0.key >> 12) != Int64(source) || (($0.key >> 8) & 0x0f) != channel }
        } else { return }
        let next = Set(held.values.flatMap { $0.values })
        if notes != next { notes = next }
    }
    func reset(track: UUID) {
        held[track] = nil; activities[track]?.reset()
        let next = Set(held.values.flatMap { $0.values })
        if notes != next { notes = next }
    }
    func reset() { held.removeAll(); if !notes.isEmpty { notes = [] }; activities.values.forEach { $0.reset() } }
}

// The footer monitor follows hardware input independently of armed instruments.
@MainActor final class KeyboardMIDIMonitor: ObservableObject {
    static let shared = KeyboardMIDIMonitor()
    @Published private(set) var notes: Set<UInt8> = []
    private struct Source: Hashable { let device: Int32; let channel: UInt8 }
    private var held: [Source: Set<UInt8>] = [:]
    var channel: Int = max(0, min(16, UserDefaults.standard.integer(forKey: "jaras.keyboard.channel"))) {
        didSet { held.removeAll(); notes = []; UserDefaults.standard.set(channel, forKey: "jaras.keyboard.channel") }
    }
    func receive(source: Int32, status: UInt8, number: UInt8, value: UInt8) {
        guard status >= 0x80, status < 0xf0, channel == 0 || Int(status & 15) + 1 == channel else { return }
        let source = Source(device: source, channel: status & 15)
        switch status & 0xf0 {
        case 0x90 where value > 0: held[source, default: []].insert(number)
        case 0x80, 0x90: held[source]?.remove(number)
        case 0xb0 where number == 120 || number == 123: held[source] = nil
        default: return
        }
        let next = Set(held.values.flatMap { $0 })
        if notes != next { notes = next }
    }
}

@MainActor final class TrackMeterLevel: ObservableObject {
    @MainActor final class PeakHold: ObservableObject {
        @Published private(set) var decibels: Double?
        private var maximum = 0.0
        static let displayThreshold = pow(10.0, -24.0 / 20)
        static let muteThreshold = pow(10.0, 30.0 / 20)
        func record(_ amplitude: Double) {
            guard amplitude.isFinite, amplitude >= Self.displayThreshold, amplitude > maximum else { return }
            maximum = amplitude
            let db = (20 * log10(amplitude) * 100).rounded() / 100
            if decibels != db { decibels = db }
        }
        func clear() { maximum = 0; if decibels != nil { decibels = nil } }
    }
    let peakHold = PeakHold()
    @Published private(set) var levels = SIMD2<Double>(repeating: 0)
    var level: Double { max(levels.x, levels.y) }
    // Instant attack, with no peak hold on the moving bars. The separate
    // numeric readout retains its maximum until explicitly cleared. Silence,
    // Stop and elapsed time never reset this separately held number.
    static let releaseDecibelsPerSecond = 48.0
    private var envelope = SIMD2<Double>(repeating: 0)
    func reset() { envelope = .zero; if levels != .zero { levels = .zero } }
    func update(peak: Double, elapsed: Double) { update(left: peak, right: peak, elapsed: elapsed) }
    func update(left: Double, right: Double, elapsed: Double) {
        peakHold.record(max(left, right))
        let peaks = SIMD2(left, right)
        let decay = envelope == .zero ? 0 : pow(10, -Self.releaseDecibelsPerSecond * max(0, elapsed) / 20)
        var changed = false
        for channel in 0..<2 {
            let input = peaks[channel].isFinite ? max(0, peaks[channel]) : 0
            if input == 0 && envelope[channel] == 0 && levels[channel] == 0 { continue }
            envelope[channel] = max(input, envelope[channel] * decay)
            if envelope[channel] < 0.001 { envelope[channel] = 0 }
            let oldDB = levels[channel] > 0 ? max(-60, 20 * log10(levels[channel])) : -60
            let newDB = envelope[channel] > 0 ? max(-60, 20 * log10(envelope[channel])) : -60
            if (envelope[channel] == 0 && levels[channel] != 0) || abs(newDB - oldDB) >= 0.06 { changed = true }
        }
        if changed { levels = envelope }
    }
}

/// Item edges gate timecode output; the owning region keeps its clock origin.
struct TimecodePlaybackSpan {
    let clip: AudioClip
    let time: Double
    let end: Double
    let delay: Double
    init?(song: Song, track: Track, position: Double, settings: TimecodeSettings, preferredRegion: UUID?) {
        let preferred = preferredRegion.map(Project.timecodeItemID)
        var current: AudioClip?, upcoming: AudioClip?
        for clip in track.clips where !clip.isProjectionMedia {
            let contains = position >= clip.startTime && position < clip.startTime + clip.duration
            if clip.id == preferred && contains { current = clip; break }
            if contains && (current == nil || clip.startTime < current!.startTime) { current = clip }
            if clip.startTime <= position + 2 && clip.startTime + clip.duration > position && (upcoming == nil || clip.startTime < upcoming!.startTime) { upcoming = clip }
        }
        guard let clip = current ?? upcoming else { return nil }
        self.clip = clip
        let settings = clip.timecode ?? settings
        // XOR namespace is reversible; avoid converting every region UUID.
        let regionID = Project.timecodeItemID(clip.id)
        let region = song.parts.first { $0.id == regionID }
        let origin = settings.regionRelative ? region?.startTime ?? clip.startTime : 0
        delay = max(0, clip.startTime - position)
        time = max(position, clip.startTime) - origin + settings.offset
        end = clip.startTime + clip.duration - origin + settings.offset
    }
}

/// The UI schedules file segments. AVAudioEngine streams and mixes off the UI thread.
@MainActor final class StemAudioPlayback {
    static var shared = StemAudioPlayback(engine: AudioDeviceSettings.shared.engine)
    private let auxiliarySelectedHardware: Bool
    private let engine: AVAudioEngine
    private var mobileOutput: JarasMobileAudioOutput?
    private var licenseAllowed = true
    private var usesSelectedHardware: Bool {
        #if os(iOS)
        realtime && engine === AudioDeviceSettings.shared.engine
        #else
        realtime && !engine.isInManualRenderingMode && (engine === AudioDeviceSettings.shared.engine || auxiliarySelectedHardware)
        #endif
    }
    private var outputAllowed: Bool {
        guard usesSelectedHardware else { return true }
        #if os(iOS)
        guard deviceSessionActive, mobileHardwareStop == nil, AudioDeviceSettings.shared.localSessionEnabled,
              !AudioDeviceSettings.shared.localSessionInterrupted,
              !AudioDeviceSettings.shared.localSessionReconfiguring else { return false }
        #endif
        return AudioDeviceSettings.shared.selectedUID != "none"
    }
    #if os(macOS)
    private func requireSelectedOutput() throws {
        try AudioDeviceSettings.shared.requireSelectedOutput()
        guard auxiliarySelectedHardware else { return }
        guard let device = AudioDeviceSettings.shared.devices.first(where: { $0.id == AudioDeviceSettings.shared.selectedUID }),
              let unit = engine.outputNode.audioUnit else { throw ProjectError.invalid("Audio output is unavailable") }
        var actual: AudioDeviceID = 0
        var bytes = UInt32(MemoryLayout<AudioDeviceID>.size)
        let read = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &bytes)
        if read == noErr, actual == device.hardwareID { return }
        engine.stop()
        var selected = AudioDeviceID(device.hardwareID)
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, bytes)
        guard status == noErr else { throw ProjectError.invalid(String(format: "Unable to open audio device (%d).", status)) }
    }
    #endif
    func setLicenseAllowed(_ allowed: Bool) {
        licenseAllowed = allowed
        // Every hardware channel (master, direct outs, click, LTC and instruments)
        // converges here. Track/master controls never write this final gain.
        #if os(macOS)
        let routeConfirmed = !usesSelectedHardware || AudioDeviceSettings.shared.outputDeviceIsBound
        #else
        let routeConfirmed = true
        #endif
        engine.mainMixerNode.outputVolume = allowed && outputAllowed && routeConfirmed ? 1 : 0
    }
    // An independent silent source keeps the hardware rendering even with an
    // empty project, a muted Master, or no transport voices scheduled.
    private let deviceSilence = AVAudioSourceNode { silent, _, _, buffers in
        silent.pointee = true
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        return noErr
    }
    private var deviceSilenceAttached = false
    private var deviceSessionActive = false
    private var lastDeviceHealthCheck = 0.0
    private var deviceActivity: NSObjectProtocol?
    private var clickGenerators: [JarasMetronomeGenerator] = []
    private var clickTrackID: UUID?
    private var clickSections: [ClickTrackSection] = []
    private var clickSample: Data?
    private var clickSoundPath: String?
    private var metronome: JarasMetronomeGenerator?
    private let metronomeRoute = JarasChannelRouter.makeNode()
    private var metronomeSoundRevision: UInt64?
    private var metronomeTiming: [TimelineTempoSection] = []
    private var metronomeMarkers: [TimelineMarker]?
    private var metronomeBPM: Double?
    private var metronomeMeter = [Int]()
    private var metronomeSounds: (Data, Data) = (Data(), Data())
    private var masterBus = AVAudioMixerNode()
    private var masterEffects = NativeEffectsChain()
    private var analysisEffects: [String:Set<String>] = [:]
    var instrumentFile: ((String) -> (URL,Bool)?)?
    private struct InstrumentVoiceKey: Hashable { let track: UUID; let effect: String }
    private var samplers: [InstrumentVoiceKey:JarasSoundFont] = [:]
    private var instrumentRequests: [InstrumentVoiceKey:UUID] = [:]
    private var instrumentNames: [InstrumentVoiceKey:String] = [:]
    private var instrumentGeneration = UUID()
    private var masterFXSettings = NativeFXSettings()
    private var masterChannelMode = JarasEqualizer.makeNode()
    private var masterGain = AVAudioUnitEQ(numberOfBands: 0)
    private var masterRoutes = [JarasChannelRouter.makeNode()]
    private var timecodePhaseInverted = false
    private var masterPatches: [OutputPatch] = [.stereo]
    private var appliedRoutes: [ObjectIdentifier: [OutputPatch]] = [:]
    let masterMeter = TrackMeterLevel()
    private var masterConfigured = false
    private let masterSlot: UInt = 0
    private let peaks = JarasMeterBank()
    private var directory: URL?
    var mediaDirectory: URL? { directory }
    private var preparedOutputFormat: AVAudioFormat?
    private var latestPlayback: (snapshot: ShowSnapshot, revision: UInt64)?
    private var deviceRecovery: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?
    var prepareAfterDeviceChange: (() throws -> Void)?
    var beforeAudioGraphReset: () -> Void = {}
    var afterAudioGraphReset: () -> Void = {}
    private var files: [String: AVAudioFile] = [:]
    private struct OnsetKey: Hashable { let path: String; let first: AVAudioFramePosition; let frames: AVAudioFrameCount }
    private var onsetPreparationKey: String?
    private var preparedOnsets: [OnsetKey: AVAudioPCMBuffer] = [:]
    private let syncDiagnosticsEnabled = ProcessInfo.processInfo.environment["CATLIVE_AUDIO_SYNC_DIAGNOSTICS"] == "1"
    private let syncDiagnosticsQueue = DispatchQueue(label: "CatLive.audioSyncDiagnostics", qos: .utility)
    private func recordSyncDiagnostics(_ keys: [VoiceKey], phase: String) {
        guard syncDiagnosticsEnabled else { return }
        let now = mach_absolute_time()
        let records: [[String: Any]] = keys.compactMap { key in
            guard let voice = voices[key] else { return nil }
            let node = voice.player.lastRenderTime
            let player = node.flatMap { voice.player.playerTime(forNodeTime: $0) }
            return ["phase": phase, "host": now, "head": key.head, "item": voice.clip.id.uuidString,
                    "name": voice.clip.name, "track": voice.track.uuidString,
                    "clipStart": voice.clip.startTime, "offset": voice.clip.sourceOffset,
                    "rate": voice.clip.audioRate, "pitchCents": voice.pitch,
                    "fileRate": voice.file.processingFormat.sampleRate,
                    "firstSourceFrame": voice.scheduledSourceStart,
                    "onsetSample": voice.scheduledOnset?.sampleTime ?? -1,
                    "onsetHost": voice.scheduledOnset?.hostTime ?? 0,
                    "nodeSample": node?.sampleTime ?? -1, "nodeHost": node?.hostTime ?? 0,
                    "playerSample": player?.sampleTime ?? -1, "playerRate": player?.sampleRate ?? 0,
                    "processingDelay": voice.scheduledProcessingDelay,
                    "headHost": headAudioClock[key.head]?.host ?? 0,
                    "headPosition": headAudioClock[key.head]?.position ?? -1,
                    "sourceClock": sourcePositionAtRenderClock(voice) ?? -1,
                    "gainHost": voice.gain.lastRenderTime?.hostTime ?? 0,
                    "gainSample": voice.gain.lastRenderTime?.sampleTime ?? -1,
                    "stretchHost": voice.stretch.lastRenderTime?.hostTime ?? 0,
                    "stretchSample": voice.stretch.lastRenderTime?.sampleTime ?? -1,
                    "masterHost": engine.outputNode.lastRenderTime?.hostTime ?? 0,
                    "masterSample": engine.outputNode.lastRenderTime?.sampleTime ?? -1]
        }
        guard !records.isEmpty, let data = try? JSONSerialization.data(withJSONObject: records) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-audio-sync-\(ProcessInfo.processInfo.processIdentifier).jsonl")
        syncDiagnosticsQueue.async {
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            guard let file = try? FileHandle(forWritingTo: url) else { return }
            defer { try? file.close() }
            do { try file.seekToEnd(); try file.write(contentsOf: data); try file.write(contentsOf: Data([10])) } catch { }
        }
    }
    private var voices: [VoiceKey: Voice] = [:]
    private var retiredVoices: [Voice] = []
    /// File sources still retained by the graph must survive timeline cleanup,
    /// including voices retiring after an edit and voices prepared for a seek.
    var activeMediaURLs: Set<URL> {
        let retained = Array(voices.values) + retiredVoices + idleVoices.values.flatMap { $0 } + effectTails.values.map(\.voice)
        return Set(retained.map { $0.file.url.standardizedFileURL.resolvingSymlinksInPath() })
    }
    // Idle sources retain their graph connections. Transport commands only stop
    // and reschedule PCM; graph ownership changes on project/device teardown.
    private var pitchClipRevision: UInt64?
    private var pitchParts: [Part] = []
    private var clipPitches: [UUID: Float] = [:]
    private var suspendedVoiceOutputs = Set<ObjectIdentifier>()
    private var idleVoices: [UUID: [Voice]] = [:]
    private var voicePreparation: Task<Void, Never>?
    private var preparationKey: String?
    private struct EffectTail { var voice: Voice; let until: Double }
    private var effectTails: [VoiceKey: EffectTail] = [:]
    private let emptyFX = NativeFXSettings()
    private var sectionJumpSerial: UInt64 = 0
    private struct PreparedJump {
        var boundary: Double
        var destination: Double
        var host: UInt64
        var section: UUID?
        var region: UUID?
        var revision: UInt64
    }
    private var preparedJump: PreparedJump?
    private var appliedJumpBoundaries: [ObjectIdentifier: UInt64] = [:]
    private var boundaryTails: [(Voice, UInt64)] = []
    // Keep future-head work below one long UI stall. All batches retain the
    // same sample-clock deadline; this changes preparation, never onset time.
    static func jumpPreparationBatchSize(pending: Int, seconds: Double, interval: Double) -> Int {
        guard pending > 0 else { return 0 }
        let cadence = max(1.0 / 30.0, min(0.25, interval))
        let passes = max(1, Int(max(0, seconds - 0.15) / (cadence * 2)))
        return max(1, (pending + passes - 1) / passes)
    }
    private func retireSilently(_ voice: Voice) {
        JarasVoiceGain.setRenderEnabled(voice.gain, enabled: false)
        retiredVoices.append(voice)
    }
    private func cancelPreparedJump() {
        if preparedJump != nil { metronome?.cancelJump(); clickGenerators.first?.cancelJump() }
        appliedJumpBoundaries.removeAll(keepingCapacity: true)
        for key in Array(voices.keys) where key.head == 2 {
            if let voice = voices.removeValue(forKey: key) { retireSilently(voice) }
        }
        for voice in voices.values { voice.effects?.setPlaybackBoundary() }
        headAudioClock[2] = nil; lastPosition[2] = nil; preparedJump = nil
    }
    private func upcomingJump(_ transport: TransportState, song: Song, setlist: RegionSetlist?) -> (Double, Double, UUID?, UUID?)? {
        guard transport.playing else { return nil }
        var result: (Double, Double, UUID?, UUID?)?
        if transport.loop.enabled, let a = transport.loop.start, let b = transport.loop.end, b > a, b > transport.position,
           transport.multiLoop?.released != true { result = (b, a, nil, nil) }
        // Queues share the sample-clock scheduling/promotion used for section
        // jumps. A loop still owns its boundary; an already-running Sub Play
        // owns its handoff. Prepare-only must never schedule incoming audio.
        if result == nil, !transport.subPlay.playing, setlist?.preparesWithoutPlayback != true,
           let queued = song.parts.first(where: { $0.id == transport.queuedRegionId }),
           let active = song.parts.first(where: { $0.id == transport.regionId }) {
            let parent = active.parentRegionID.flatMap { id in song.parts.first(where: { $0.id == id }) }
            let boundary = transport.ignoreNextEnd ?? parent?.endTime ?? active.endTime
            if boundary > transport.position { result = (boundary, queued.startTime, nil, queued.id) }
        }
        if let id = transport.queuedSectionMarkerId,
           let destination = song.sectionDestinationPosition(id),
           let trigger = song.nextSectionTrigger(for: transport),
           result == nil || trigger <= result!.0 { result = (trigger, destination, id, nil) }
        return result
    }
    private var subPlayPromotion: UInt64 = 0
    private var transportWasRunning = false
    // Keep the prepared audio graph clock running throughout the device session.
    // A disarmed instrument may still be sustaining a note, so its graph stays
    // awake until an explicit Stop releases MIDI notes.
    private var renderEnabled = false
    private var instrumentRenderPending = false
    @MainActor private struct TrackBus {
        let mix = AVAudioMixerNode()
        // Merge printed MIDI after the ordered track FX, before live controls.
        let processedMix = AVAudioMixerNode()
        func input(for clip: AudioClip) -> AVAudioMixerNode { clip.frozenMIDI == true ? processedMix : mix }
        // Keep each route alive between clips, including tracks entering later regions.
        let silence = AVAudioSourceNode { silent, _, _, buffers in
            silent.pointee = true
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
        let masterSend = AVAudioMixerNode()
        let groupSend = AVAudioMixerNode()
        let internalSend = AVAudioMixerNode()
        // One existing native kernel applies fader, stereo balance, phase and
        // mute/solo. It also captures peaks directly from the post-control PCM.
        let controls = JarasEqualizer.makeNode()
        let hardware = [JarasChannelRouter.makeNode()]
        let effects = NativeEffectsChain()
    }
    private var trackBuses: [UUID: TrackBus] = [:]
    private var transportFadeEndpointReached = false
    private var transportFadeSchedule: (tracks: Set<UUID>, duration: Double, host: UInt64, sample: Double)?
    /// The existing sample-clock envelope lives after the track insert chain.
    /// Schedule it once: UI stalls, automation and meter refreshes cannot step
    /// the ramp or let effect tails escape it.
    func startTransportFade(tracks ids: Set<UUID>, duration: Double) {
        transportFadeEndpointReached = false
        let seconds = duration.isFinite ? min(5, max(1, duration)) : 3
        let manual = engine.isInManualRenderingMode
        transportFadeSchedule = (ids, seconds, manual ? 0 : mach_absolute_time(),
            manual ? Double(engine.manualRenderingSampleTime) : 0)
        for id in ids { if let bus = trackBuses[id] { configureTransportFade(bus, id: id) } }
    }
    private func configureTransportFade(_ bus: TrackBus, id: UUID) {
        guard let fade = transportFadeSchedule, fade.tracks.contains(id) else { return }
        JarasEqualizer.setInputFade(bus.controls, fadeIn: 0, fadeOut: fade.duration,
            fadeInCurve: 0, fadeInSCurve: 0, fadeOutCurve: 0, fadeOutSCurve: 0,
            duration: fade.duration, position: 0, hostTime: fade.host, sampleTime: fade.sample)
    }
    func setTransportFadeGains(_ gains: [UUID: Double]) {
        // Intermediate gains are presentation samples; the audio kernel already
        // owns the continuous envelope. An empty map restores unity immediately.
        guard gains.isEmpty else { transportFadeEndpointReached = gains.values.allSatisfy { $0 <= 0 }; return }
        // After automatic Stop, keep the audio envelope at zero until the next
        // Play. Restoring the fader display must not revive a plugin tail.
        if transportFadeEndpointReached && !transportWasRunning { return }
        clearTransportFade()
    }
    private func clearTransportFade() {
        guard let fade = transportFadeSchedule else { return }
        transportFadeEndpointReached = false; transportFadeSchedule = nil
        for id in fade.tracks { if let bus = trackBuses[id] {
            JarasEqualizer.setInputFade(bus.controls, fadeIn: 0, fadeOut: 0,
                duration: 0, position: 0, hostTime: 0, sampleTime: 0)
        } }
    }
    var armedMIDIRecordingTracks: Set<UUID> = []
    private struct InputMonitor {
        let source: AVAudioSourceNode
        let gate: AVAudioMixerNode
        let input: JarasCaptureRing?
        let firstChannel: Int
        let channels: Int
    }
    private var inputMonitors: [UUID: InputMonitor] = [:]
    func setInputMonitor(_ track: UUID, source: AVAudioSourceNode?, format: AVAudioFormat? = nil, input: JarasCaptureRing? = nil, firstChannel: Int = 0, channels: Int = 2) {
        if inputMonitors[track]?.source === source { return }
        if let old = inputMonitors.removeValue(forKey: track) { engine.detach(old.source); engine.detach(old.gate) }
        if let source, let format {
            guard masterConfigured, outputAllowed else { return }
            let bus = trackBus(for: track)
            let gate = AVAudioMixerNode()
            gate.outputVolume = tracks[track]?.inputMonitoring == false ? 0 : 1
            engine.attach(source); engine.attach(gate)
            engine.connect(source, to: gate, format: format)
            engine.connect(gate, to: bus.mix, fromBus: 0, toBus: availableInputBus(track: track, node: bus.mix), format: format)
            inputMonitors[track] = InputMonitor(source: source, gate: gate, input: input, firstChannel: firstChannel, channels: channels)
        }
        if deviceSessionActive { startMeterClock() }
    }
    func hasInputMonitor(_ track: UUID) -> Bool { inputMonitors[track] != nil }
    private var armedInstrumentTracks: Set<UUID> = []
    func setArmedInstrumentTracks(_ armed: Set<UUID>) {
        guard armedInstrumentTracks != armed else { return }
        let changed = armedInstrumentTracks.symmetricDifference(armed)
        armedInstrumentTracks = armed
        if !armed.isEmpty { instrumentRenderPending = true }
        setGraphRenderEnabled(transportWasRunning || instrumentRenderPending)
        if deviceSessionActive { startMeterClock() }
        #if os(macOS)
        for id in changed { trackBuses[id]?.effects.enableInstrumentMIDI(armed.contains(id)) }
        #endif
    }
    private func setGraphRenderEnabled(_ requested: Bool) {
        // Suspending upstream pulls freezes prepared player/time-stretch clocks;
        // waking only the output device still delays the first PCM after idle.
        // Stop silences and resets sources, but the live graph remains clocked.
        let enabled = requested || deviceSessionActive
        guard realtime, renderEnabled != enabled else { return }
        renderEnabled = enabled
        for route in masterRoutes { JarasChannelRouter.setRenderEnabled(route, enabled: enabled) }
        for bus in trackBuses.values {
            for route in bus.hardware { JarasChannelRouter.setRenderEnabled(route, enabled: enabled) }
        }
        for route in timecodeRoutes { JarasChannelRouter.setRenderEnabled(route, enabled: enabled) }
        if metronome != nil { JarasChannelRouter.setRenderEnabled(metronomeRoute, enabled: enabled) }
    }
    private var groupConnections: [UUID: UUID] = [:]
    private var trackConnections: Set<TrackConnection> = []
    private var tracks: [UUID: Track] = [:]
    // Keep routing connections stable for Undo, but release deleted tracks'
    // processors and model workers once instead of resetting them on every edit.
    private var retiredTrackEffects = Set<UUID>()
    /// nil means every track is eligible; a solo permits its complete subtree and the ancestors that carry its audio.
    private var soloAudibleTracks: Set<UUID>?
    private var clips: [(UUID, AudioClip)] = []
    private var playbackClipIndex = AudioClipPlaybackIndex(clips: [])
    private var missingAudioPaths = Set<String>()
    private var fragmentPlaybackStarts: [UUID: Double] = [:]
    private var clipIndices: [UUID: Int] = [:]
    private var clipFragments: [UUID: [UUID]] = [:]
    private var contiguousNext: [UUID: UUID] = [:]
    private var contiguousPrevious: [UUID: UUID] = [:]
    private var contiguousSourceEnd: [UUID: Double] = [:]
    private var fragmentStarts: [UUID: Double] = [:]
    private var trackPeaks: [UUID: JarasMeterBank] = [:]
    private var meters: [UUID: TrackMeterLevel] = [:]
    private var lastTempoEditTime = -Double.infinity
    private struct AutomatedMix {
        var gain: Double?
        var pan: Double?
        var mute: Bool?
        var trim = true
        var baseGain = 1.0
        var basePan = 0.0
    }
    private var automatedMix: [UUID: AutomatedMix] = [:]
    private var automationPlan: [(UUID, TrackAutomation)] = []
    private var automationPlanRevision: UInt64?
    private var automationSong: UUID?
    private var itemAutomationVoiceKeys = Set<VoiceKey>()
    private var automationOverrides: [UUID: [UUID: Double]] = [:]
    private var externalAutomationValues: [String: Double] = [:]
    private var externalAutomationBase: [String: (UUID, String, UInt32, Double)] = [:]
    func overrideAutomation(_ track: UUID?, envelope: UUID, value: Double?) {
        let id = track ?? MultiLoopTrack.masterID
        automationOverrides[id, default: [:]][envelope] = value
    }
    private func automationGain(_ id: UUID, manual: Double) -> Double {
        guard let mix = automatedMix[id], let value = mix.gain else { return manual }
        return mix.trim ? manual * value / max(0.000001, mix.baseGain) : value
    }
    private func applyAutomation(_ snapshot: ShowSnapshot, song: Song, revision: UInt64) {
        let masterID = MultiLoopTrack.masterID
        if automationPlanRevision != revision || automationSong != song.id {
            automationSong = song.id
            automationPlan = song.tracks.compactMap { track in track.automation.map { (track.id, $0) } }
            if let automation = snapshot.project.masterAutomation { automationPlan.append((masterID, automation)) }
            automationPlanRevision = revision
        }
        guard !automationPlan.isEmpty || !automatedMix.isEmpty || !externalAutomationBase.isEmpty else { return }
        let transport = snapshot.transport
        let head = transport.subPlay.playing ? 1 : 0
        let position: Double
        if realtime, transport.playing || transport.subPlay.playing, let anchor = headAudioClock[head] {
            let now = mach_absolute_time()
            position = anchor.position + (now >= anchor.host ? AVAudioTime.seconds(forHostTime: now-anchor.host) : -AVAudioTime.seconds(forHostTime: anchor.host-now))
        } else { position = transport.subPlay.playing ? transport.subPlay.position : transport.playing ? transport.position : transport.editPosition ?? transport.position }
        var active = Set<UUID>(), externalActive = Set<String>()
        for (id, automation) in automationPlan {
            let target: UUID? = id == masterID ? nil : id
            let baseFX = target.flatMap { tracks[$0]?.fx } ?? (target == nil ? masterFXSettings : nil) ?? NativeFXSettings()
            var fx = baseFX, mix = AutomatedMix(); mix.trim = automation.mode == .trimRead
            if automation.enabled {
                active.insert(id)
                for envelope in automation.active {
                    let value = automationOverrides[id]?[envelope.id] ?? envelope.value(at: position)
                    switch envelope.target.kind {
                    case .volume: mix.gain = TrackEnvelope.gain(value); mix.baseGain = TrackEnvelope.gain(envelope.defaultValue)
                    case .pan: mix.pan = value * 2 - 1; mix.basePan = envelope.defaultValue * 2 - 1
                    case .mute: mix.mute = value >= 0.5
                    case .nativeFX: _ = envelope.target.native?.apply(normalized: value, to: &fx)
                    case .externalFX:
                        #if os(macOS)
                        guard let plugin = envelope.target.plugin, let parameter = envelope.target.parameter,
                              baseFX.externalPlugins?.contains(where: { $0.id == plugin && baseFX.inserted.contains($0.effectKey) }) == true,
                              let node = effects(for: target)?.externalNode(plugin) else { continue }
                        let key = id.uuidString + "/" + envelope.target.key
                        externalActive.insert(key)
                        if externalAutomationBase[key] == nil {
                            let original = JarasVST3.parameters(node, identifier: plugin).first { ($0["id"] as? UInt32) == parameter }?["value"] as? Double
                            if let original { externalAutomationBase[key] = (id, plugin, parameter, original) }
                        }
                        if externalAutomationValues[key] != value {
                            JarasVST3.setParameter(node, identifier: plugin, parameter: parameter, value: value)
                            externalAutomationValues[key] = value
                        }
                        #endif
                    }
                }
            }
            automatedMix[id] = mix
            effects(for: target)?.apply(fx)
            if id == masterID {
                applyMasterGain()
                JarasEqualizer.setInputPan(masterChannelMode, pan: min(1, max(-1, mix.pan.map { mix.trim ? masterPan + $0 - mix.basePan : $0 } ?? masterPan)))
            } else if let track = tracks[id], let bus = trackBuses[id] {
                applyTrackGain(id)
                JarasEqualizer.setInputPan(bus.controls, pan: min(1, max(-1, mix.pan.map { mix.trim ? track.pan + $0 - mix.basePan : $0 } ?? track.pan)))
            }
        }
        for id in Set(automatedMix.keys).subtracting(active) {
            automatedMix[id] = nil
            if id == masterID {
                applyMasterGain(); JarasEqualizer.setInputPan(masterChannelMode, pan: masterPan); masterEffects.apply(masterFXSettings)
            } else if let track = tracks[id], let bus = trackBuses[id] {
                applyTrackGain(id); JarasEqualizer.setInputPan(bus.controls, pan: track.pan); bus.effects.apply(track.fx ?? NativeFXSettings())
            }
        }
        #if os(macOS)
        for key in Set(externalAutomationBase.keys).subtracting(externalActive) {
            if let (id, plugin, parameter, value) = externalAutomationBase.removeValue(forKey: key),
               let node = effects(for: id == masterID ? nil : id)?.externalNode(plugin) {
                JarasVST3.setParameter(node, identifier: plugin, parameter: parameter, value: value)
            }
            externalAutomationValues[key] = nil
        }
        #endif
    }
    /// Take automation is evaluated on its own voice and transport head. A
    /// neighbouring/overlapping item on the same track must never inherit it.
    private func applyItemAutomation(_ transport: TransportState) {
        guard !itemAutomationVoiceKeys.isEmpty else { return }
        for key in itemAutomationVoiceKeys {
            guard var voice = voices[key] else { itemAutomationVoiceKeys.remove(key); continue }
            let position: Double
            if realtime, let anchor = headAudioClock[key.head] {
                let now = mach_absolute_time()
                position = anchor.position + (now >= anchor.host ? AVAudioTime.seconds(forHostTime: now-anchor.host) : -AVAudioTime.seconds(forHostTime: anchor.host-now))
            } else { position = key.head == 0 ? transport.position : key.head == 1 ? transport.subPlay.position : voice.clip.startTime }
            let clip = voice.clip, values = clip.automatedValues(at: min(voice.clip.startTime + voice.clip.duration, position))
            var externalActive = Set<String>()
            #if os(macOS)
            for entry in values.external {
                guard let plugin = entry.target.plugin, let parameter = entry.target.parameter,
                      values.fx.externalPlugins?.contains(where: { $0.id == plugin && values.fx.inserted.contains($0.effectKey) }) == true,
                      let node = voice.effects?.externalNode(plugin) else { continue }
                let id = entry.target.key, value = entry.value
                externalActive.insert(id)
                if voice.automationExternalBase[id] == nil {
                    let original = JarasVST3.parameters(node, identifier: plugin).first { ($0["id"] as? UInt32) == parameter }?["value"] as? Double
                    if let original { voice.automationExternalBase[id] = (plugin, parameter, original) }
                }
                if voice.automationExternalValues[id] != value {
                    JarasVST3.setParameter(node, identifier: plugin, parameter: parameter, value: value)
                    voice.automationExternalValues[id] = value
                }
            }
            #endif
            #if os(macOS)
            for id in Set(voice.automationExternalBase.keys).subtracting(externalActive) {
                if let (plugin, parameter, value) = voice.automationExternalBase.removeValue(forKey: id),
                   let node = voice.effects?.externalNode(plugin) { JarasVST3.setParameter(node, identifier: plugin, parameter: parameter, value: value) }
                voice.automationExternalValues[id] = nil
            }
            #endif
            if values.nativeActive || voice.automationNativeApplied { applyClipFX(values.fx, to: &voice) }
            voice.automationNativeApplied = values.nativeActive
            voice.automationApplied = clip.automation?.enabled == true
            voice.player.volume = values.muted || values.gain <= 0 ? 0 : 1
            voice.player.pan = Float(values.pan)
            JarasVoiceGain.setDecibels(voice.gain, decibels: values.muted || values.gain <= 0 ? -96 : min(24, max(-96, 20 * log10(values.gain))))
            setVoice(voice, for: key)
        }
    }
    private func setVoice(_ voice: Voice?, for key: VoiceKey) {
        voices[key] = voice
        if let voice, voice.automationApplied || (voice.clip.automation?.enabled == true && voice.clip.automation?.envelopes.contains(where: \.enabled) == true) {
            if !itemAutomationVoiceKeys.contains(key) { itemAutomationVoiceKeys.insert(key) }
        } else if itemAutomationVoiceKeys.contains(key) { itemAutomationVoiceKeys.remove(key) }
    }
    private func restoreItemAutomation(_ voice: inout Voice) {
        #if os(macOS)
        for (_, (plugin, parameter, value)) in voice.automationExternalBase {
            if let node = voice.effects?.externalNode(plugin) { JarasVST3.setParameter(node, identifier: plugin, parameter: parameter, value: value) }
        }
        #endif
        voice.automationExternalBase.removeAll(); voice.automationExternalValues.removeAll()
        if voice.automationNativeApplied { applyClipFX(voice.clip.fx ?? emptyFX, to: &voice) }
        voice.automationApplied = false; voice.automationNativeApplied = false
    }
    private var revision: UInt64?
    private var songID: UUID?
    private var timecodeTrackID: UUID?
    private var timecodePreviewGain: (value: Double, original: Double)?
    private var lastVideoNoAudio: Bool?
    private var silentVideoFiles = Set<String>()
    private var tempo: Double?
    private var allowsTempoChanges = false
    private var voiceClockAnchors: [ObjectIdentifier: (node: AVAudioTime, player: AVAudioTime)] = [:]
    private var timecodeGenerator: JarasTimecodeGenerator?
    private var timecodeRoutes: [AVAudioUnitEffect] = []
    private var timecodeAnchor: (key: String, position: Double, host: Double)?
    private var masterPan = 0.0
    private var master = 1.0
    private var loopGainState: MultiLoopPlayback?
    private var loopGainPlan = MultiLoopGainPlan()
    private var loopGainPlanKey: (song: UUID, revision: UInt64, rules: [MultiLoopTrack])?
    private var masterMono = false
    private var masterMuted = false
    private var masterSolo = false
    private var lastPosition: [Int: Double] = [:]
    private var headAudioClock: [Int: (position: Double, host: UInt64)] = [:]
    /// Position scheduled at the output, expressed at the UI sample epoch.
    /// The transport is ahead while players fill their processing latency.
    func presentationPosition(head: Int, sampledAt: Double) -> Double? {
        guard realtime, let anchor = headAudioClock[head] else { return nil }
        let host = mach_absolute_time()
        let elapsed = host >= anchor.host ? AVAudioTime.seconds(forHostTime: host - anchor.host) : -AVAudioTime.seconds(forHostTime: anchor.host - host)
        let sinceSample = ProcessInfo.processInfo.systemUptime - sampledAt
        return max(0, anchor.position + elapsed - sinceSample)
    }
    private func audioHostTime(position: Double, head: Int) -> UInt64? {
        guard let anchor = headAudioClock[head] else { return nil }
        let delta = position - anchor.position
        let ticks = AVAudioTime.hostTime(forSeconds: abs(delta))
        return delta >= 0 ? anchor.host + ticks : anchor.host - min(anchor.host, ticks)
    }
    private func nodeSampleTime(host: UInt64, anchor: AVAudioTime?) -> AVAudioFramePosition? {
        guard let anchor, anchor.isSampleTimeValid, anchor.sampleRate > 0 else { return nil }
        if let clock = mobileOutput?.renderTime, !anchor.isHostTimeValid {
            let elapsed = host >= clock.hostTime ? AVAudioTime.seconds(forHostTime: host - clock.hostTime) : -AVAudioTime.seconds(forHostTime: clock.hostTime - host)
            return AVAudioFramePosition(((Double(clock.sampleTime) / clock.sampleRate + elapsed) * anchor.sampleRate).rounded())
        }
        guard anchor.isHostTimeValid else { return nil }
        let elapsed = host >= anchor.hostTime ? AVAudioTime.seconds(forHostTime: host - anchor.hostTime) : -AVAudioTime.seconds(forHostTime: anchor.hostTime - host)
        return anchor.sampleTime + AVAudioFramePosition((elapsed * anchor.sampleRate / (anchor.audioTimeStamp.mRateScalar > 0 ? anchor.audioTimeStamp.mRateScalar : 1)).rounded())
    }
    private func configureStretch(_ stretch: AVAudioUnitTimePitch, clock: AVAudioUnitVarispeed, rate: Float, pitch: Float) {
        // TimePitch rounds fractional rates to its analysis hop: 61/60 can
        // render as 521/512, accumulating ~54 ms/min against the sample clock.
        // Use an exact binary-fraction stretch and resample the remainder.
        // Keep already-exact ratios (1, 1.25, 1.5, 2...) unchanged. Compensate
        // resampling's pitch, using small corrections within the pitch range.
        let quantum = pow(Float(2), floor(log2(rate)) - 3)
        var coarseRate = (rate / quantum).rounded() * quantum
        // A rapid drag can alternate around a quantisation boundary on every
        // UI tick. Keep the existing exact coarse ratio within a small band
        // and let Varispeed supply the remainder. This avoids repeatedly
        // reconfiguring TimePitch's analysis hop without delaying BPM edits or
        // changing their exact source-clock ratio.
        let existing = stretch.rate
        if realtime, transportWasRunning, existing > 0 {
            let ratio = rate / existing
            let compensatedPitch = pitch - 1200 * log2(ratio)
            if ratio >= 0.91, ratio <= 1.10, abs(compensatedPitch) <= 2400 {
                coarseRate = existing
            }
        }
        var remainder = rate / coarseRate
        var tuning = pitch - 1200 * log2(remainder)
        if tuning > 2400 { coarseRate -= quantum }
        if tuning < -2400 { coarseRate += quantum }
        coarseRate = min(32, max(1.0/32, coarseRate))
        remainder = rate / coarseRate
        tuning = pitch - 1200 * log2(remainder)
        if existing != coarseRate { stretch.rate = coarseRate }
        if stretch.pitch != tuning { stretch.pitch = tuning }
        if clock.rate != remainder { clock.rate = remainder }
        if stretch.bypass { stretch.bypass = false }
    }
    private var lastUpdate = ProcessInfo.processInfo.systemUptime
    private var lastMeterUpdate = 0.0
    private var meterTimer: Timer?
    private var meterTimerActive = false
    private let realtime: Bool
    private struct VoiceKey: Hashable { let clip: UUID; let head: Int }
    private struct Voice {
        let player: AVAudioPlayerNode
        let gain: AVAudioUnitEffect
        let stretch: AVAudioUnitTimePitch
        let rateClock: AVAudioUnitVarispeed
        var pitch: Float
        let usesStretch: Bool
        let track: UUID
        var clip: AudioClip
        var file: AVAudioFile
        var effects: NativeEffectsChain?
        var scheduledUntil = 0.0
        var scheduledOnset: AVAudioTime?
        var scheduledProcessingDelay = 0.0
        var scheduledSourceStart: AVAudioFramePosition = 0
        var scheduledSourceEnd: AVAudioFramePosition = 0
        var continuousSource = false
        var mixInputBus: AVAudioNodeBus = 0
        var automationApplied = false
        var automationNativeApplied = false
        var automationExternalBase: [String: (String, UInt32, Double)] = [:]
        var automationExternalValues: [String: Double] = [:]
    }
    private func sourcePositionAtRenderClock(_ voice: Voice, protectingOnsetFor leadTime: Double = 0) -> Double? {
        guard let onset = voice.scheduledOnset, let node = voice.player.lastRenderTime,
              let clock = voice.player.playerTime(forNodeTime: node) else { return nil }
        let first: AVAudioFramePosition
        if onset.isSampleTimeValid { first = onset.sampleTime }
        else if onset.isHostTimeValid, let sample = nodeSampleTime(host: onset.hostTime, anchor: node) {
            first = clock.sampleTime + sample - node.sampleTime
        } else { return nil }
        let lead = AVAudioFramePosition((leadTime * clock.sampleRate).rounded(.up))
        guard clock.sampleTime + lead >= first else { return nil }
        return Double(voice.scheduledSourceStart + max(0, clock.sampleTime - first)) / voice.file.processingFormat.sampleRate
    }
    init(engine: AVAudioEngine, realtime: Bool = true, mobileOutput: JarasMobileAudioOutput? = nil, auxiliarySelectedHardware: Bool = false) {
        self.auxiliarySelectedHardware = auxiliarySelectedHardware
        self.engine = engine; self.realtime = realtime
        self.mobileOutput = mobileOutput
        #if os(iOS)
        if mobileOutput == nil, realtime, engine === AudioDeviceSettings.shared.engine {
            self.mobileOutput = JarasMobileAudioOutput(engine: engine)
        }
        #endif
        if realtime {
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleDeviceRecovery() }
            }
        }
    }
    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        deviceRecovery?.cancel()
        if let deviceActivity { ProcessInfo.processInfo.endActivity(deviceActivity) }
    }
    private var outputFormatChanged: Bool {
        guard let previous = preparedOutputFormat else { return true }
        #if os(iOS)
        if mobileOutput != nil {
            let session = AVAudioSession.sharedInstance()
            return previous.sampleRate != session.sampleRate || previous.channelCount != session.outputNumberOfChannels
        }
        #endif
        let current = engine.isInManualRenderingMode ? engine.manualRenderingFormat : engine.outputNode.outputFormat(forBus: 0)
        return previous.sampleRate != current.sampleRate || previous.channelCount != current.channelCount
    }
    private func scheduleDeviceRecovery() {
        #if os(iOS)
        // This graph is driven by our hardware adapter. Manual graph changes
        // aren't hardware changes; AVAudioSession owns the single recovery path.
        if mobileOutput != nil { return }
        // Session recovery owns a gated engine. A second engine notification
        // must not stop it synchronously while its HAL worker is suspended.
        guard !AudioDeviceSettings.shared.localSessionReconfiguring else { return }
        #endif
        #if os(macOS)
        if usesSelectedHardware && !AudioDeviceSettings.shared.outputDeviceIsBound {
            engine.mainMixerNode.outputVolume = 0
            engine.stop()
        }
        #endif
        guard deviceSessionActive, realtime else { return }
        deviceRecovery?.cancel()
        guard outputAllowed else { deviceRecovery = nil; stop(); engine.stop(); return }
        // Core Audio may finish the output format change after CurrentDevice is
        // set. Coalesce that notification and the settings callback into one rebuild.
        deviceRecovery = Task { @MainActor [weak self] in
            #if os(iOS)
            let settlingTime: UInt64 = 150_000_000
            #else
            let settlingTime: UInt64 = 30_000_000
            #endif
            do { try await Task.sleep(nanoseconds: settlingTime) } catch { return }
            guard let self, self.deviceSessionActive else { return }
            self.deviceRecovery = nil
            do {
                #if os(macOS)
                if self.usesSelectedHardware { try self.requireSelectedOutput() }
                #endif
                self.engine.mainMixerNode.outputVolume = self.licenseAllowed && self.outputAllowed ? 1 : 0
                guard !self.engine.isRunning || self.outputFormatChanged else { return }
                try self.reconfigureDevice()
            } catch {
                #if os(macOS)
                if self.usesSelectedHardware && !AudioDeviceSettings.shared.outputDeviceIsBound {
                    self.stop(); self.engine.stop(); self.onOutputDisconnected?()
                }
                #endif
                self.onError(error)
            }
        }
    }
    /// Reconnect the output and resume both heads from the current transport.
    /// Same-format switches retain plugin instances and their open native editors.
    func reconfigureDevice() throws {
        guard deviceSessionActive || directory != nil, outputAllowed else { return }
        #if os(macOS)
        if usesSelectedHardware { try requireSelectedOutput() }
        #endif
        let previous = latestPlayback
        let rebuild = !masterConfigured || outputFormatChanged
        if rebuild { beforeAudioGraphReset() }
        defer { if rebuild { afterAudioGraphReset() } }
        stop(); engine.stop()
        discardNativeMeterPeaks()
        if rebuild {
            configureGraph(directory: directory, prepareMaster: false)
            try configureMaster()
        }
        else { engine.mainMixerNode.outputVolume = licenseAllowed && outputAllowed ? 1 : 0
            preparedOutputFormat = try JarasAudioOutputConnection.connect(engine)
        }
        if let prepareAfterDeviceChange { try prepareAfterDeviceChange() }
        else if let previous { try update(previous.snapshot, revision: previous.revision) }
        if realtime { try prepareDevice() }
    }
    func open(directory: URL) {
        #if os(iOS)
        guard mobileHardwareStop == nil else {
            onError(ProjectError.invalid(JarasLocalization.string("Audio device is unavailable. Reconnect it or choose an output in Settings.")))
            return
        }
        #endif
        deviceRecovery?.cancel(); deviceRecovery = nil
        configureGraph(directory: directory, resetProject: true)
    }
    func setMissingAudioPaths(_ paths: Set<String>) { missingAudioPaths = paths }
    private func configureGraph(directory: URL?, resetProject: Bool = false, prepareMaster: Bool = true) {
        stop()
        discardIdleVoices()
        if let generator = timecodeGenerator { engine.detach(generator.node) }
        for route in timecodeRoutes { engine.detach(route) }
        timecodeGenerator = nil; timecodeRoutes = []; timecodeAnchor = nil
        appliedRoutes.removeAll()
        // A project swap rebuilds the graph before it is warmed again by update.
        engine.stop()
        discardMIDITakeVoices()
        discardNativeMeterPeaks()
        instrumentGeneration = UUID(); instrumentRequests.removeAll(); instrumentNames.removeAll()

for sampler in samplers.values { engine.detach(sampler.node) }; samplers.removeAll()

        detachClickTrack()
        clickSample = nil; clickSoundPath = nil
        for monitor in inputMonitors.values { engine.detach(monitor.source); engine.detach(monitor.gate) }; inputMonitors.removeAll()
        for bus in trackBuses.values {
            #if os(macOS)
            if resetProject { bus.effects.releaseExternal() }
            #endif
            engine.detach(bus.silence); engine.detach(bus.mix); engine.detach(bus.processedMix); engine.detach(bus.masterSend); engine.detach(bus.groupSend); engine.detach(bus.internalSend); engine.detach(bus.controls); for route in bus.hardware { engine.detach(route) }; bus.effects.detach(from: engine)
        }
        trackBuses.removeAll(); groupConnections.removeAll(); retiredTrackEffects.removeAll()
        if let metronome { engine.detach(metronome.node); engine.detach(metronomeRoute) }; metronome = nil; metronomeSoundRevision = nil; metronomeTiming = []
        if masterConfigured {
            #if os(macOS)
            if resetProject { masterEffects.releaseExternal() }
            #endif
            for route in masterRoutes { engine.detach(route) }
            masterEffects.detach(from: engine); engine.detach(masterGain); engine.detach(masterChannelMode); engine.detach(masterBus)
            masterConfigured = false
        }
        self.directory = directory; latestPlayback = nil; automationPlanRevision = nil; automationPlan.removeAll(); automatedMix.removeAll(); automationOverrides.removeAll(); externalAutomationValues.removeAll(); externalAutomationBase.removeAll(); files.removeAll(); silentVideoFiles.removeAll(); timecodePreviewGain = nil; preparedOnsets.removeAll(); onsetPreparationKey = nil; pitchClipRevision = nil; pitchParts.removeAll(); clipPitches.removeAll(); clipFragments.removeAll(); fragmentStarts.removeAll(); trackPeaks.removeAll(); trackConnections.removeAll(); revision = nil; songID = nil; tempo = nil; subPlayPromotion = 0; sectionJumpSerial = 0
        loopGainState = nil; loopGainPlan = MultiLoopGainPlan(); loopGainPlanKey = nil
        if resetProject { clearProjectState() }
        if prepareMaster && outputAllowed {
            do { try configureMaster() }
            catch { onError(error) }
        }
        if realtime && prepareMaster {
            AudioDeviceSettings.shared.deviceChanged = { [weak self] in
                self?.scheduleDeviceRecovery()
            }
        }
    }
    /// A new document owns no item, MIDI target, editor analysis or media
    /// decision from the previous one. Device format rebuilds intentionally
    /// retain those same-project values and do not call this reset.
    private func clearProjectState() {
        transportFadeSchedule = nil; transportFadeEndpointReached = false
        tracks.removeAll(); soloAudibleTracks = nil
        clips.removeAll(); playbackClipIndex = AudioClipPlaybackIndex(clips: [])
        missingAudioPaths.removeAll(); fragmentPlaybackStarts.removeAll(); clipIndices.removeAll()
        contiguousNext.removeAll(); contiguousPrevious.removeAll(); contiguousSourceEnd.removeAll()
        analysisEffects.removeAll(); armedMIDIRecordingTracks.removeAll(); armedInstrumentTracks.removeAll()
        instrumentRenderPending = false; setGraphRenderEnabled(false)
        midiPlans.removeAll(); midiPlanRevision = nil; midiPlanSong = nil; midiTakeCacheTick = 0
        automationSong = nil; itemAutomationVoiceKeys.removeAll(); voiceClockAnchors.removeAll()
        allowsTempoChanges = false; lastTempoEditTime = -.infinity
        timecodeTrackID = nil; timecodePhaseInverted = false; lastVideoNoAudio = nil
        metronomeMarkers = nil; metronomeBPM = nil; metronomeMeter.removeAll(); metronomeSounds = (Data(), Data())
        master = 1; masterPan = 0; masterMono = false; masterMuted = false; masterSolo = false
        masterFXSettings = NativeFXSettings(); masterPatches = [.stereo]
        // These detached units belong to the project, unlike the hardware
        // engine/session. Recreate them so native tails, analysis buffers and
        // external-plugin references cannot survive a document switch.
        masterBus = AVAudioMixerNode(); masterEffects = NativeEffectsChain()
        masterChannelMode = JarasEqualizer.makeNode(); masterGain = AVAudioUnitEQ(numberOfBands: 0)
        masterRoutes = [JarasChannelRouter.makeNode()]
        masterMeter.peakHold.clear()
        for meter in meters.values { meter.peakHold.clear() }
        meters.removeAll(); preparedOutputFormat = nil
        lastUpdate = ProcessInfo.processInfo.systemUptime; lastMeterUpdate = 0
    }
    private func trackBus(for id: UUID) -> TrackBus {
        if let bus = trackBuses[id] { return bus }
        let bus = TrackBus()
        engine.attach(bus.silence); engine.attach(bus.mix); engine.attach(bus.processedMix); engine.attach(bus.masterSend); engine.attach(bus.groupSend)
        engine.attach(bus.controls); engine.attach(bus.internalSend)
        for route in bus.hardware {
            JarasChannelRouter.setRenderEnabled(route, enabled: !realtime || renderEnabled)
            engine.attach(route); engine.connect(route, to: engine.mainMixerNode, fromBus: 0, toBus: engine.mainMixerNode.nextAvailableInputBus, format: hardwareFormat)
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.sampleRate, channels: 2)!
        engine.connect(bus.masterSend, to: masterBus, fromBus: 0, toBus: masterBus.nextAvailableInputBus, format: format)
        // The permanent Master send keeps this source graph clocked. Group
        // and internal sends acquire an output in connectGroups/connectTracks
        // when first routed, so unused branches need no silent mixer render.
        for send in [bus.groupSend, bus.internalSend] {
            do {
                // An unconnected mixer defaults to 44.1 kHz. Prepare its output
                // now so first use at another rate preserves the live input.
                try send.auAudioUnit.outputBusses[0].setFormat(format)
            } catch {
                // Keep the established clocked path if the device rejects
                // preparing a disconnected mixer while its graph is running.
                engine.connect(send, to: masterBus, fromBus: 0, toBus: masterBus.nextAvailableInputBus, format: format)
            }
        }
        bus.internalSend.outputVolume = 0
        let destinations = [AVAudioConnectionPoint(node: bus.masterSend, bus: 0), AVAudioConnectionPoint(node: bus.groupSend, bus: 0), AVAudioConnectionPoint(node: bus.internalSend, bus: 0)] + bus.hardware.map { AVAudioConnectionPoint(node: $0, bus: 0) }
        engine.connect(bus.processedMix, to: bus.controls, format: format)
        bus.effects.mediaDirectory = directory
        bus.effects.attach(to: engine, input: bus.mix, format: format, destinations: [AVAudioConnectionPoint(node: bus.processedMix, bus: 0)])
        engine.connect(bus.silence, to: bus.mix, fromBus: 0, toBus: 0, format: format)
        // Build the upstream path before its fanout. On an already running
        // AVAudioEngine, installing the splitter before it has an input leaves
        // newly added tracks unclocked (including their native Click source).
        engine.connect(bus.controls, to: destinations, fromBus: 0, format: format)
        bus.effects.apply(tracks[id]?.fx ?? NativeFXSettings())
        configureTransportFade(bus, id: id)
        #if os(macOS)
        bus.effects.enableInstrumentMIDI(armedInstrumentTracks.contains(id))
        #endif
        bus.effects.observe(analysisEffects[id.uuidString] ?? [])
        bus.masterSend.outputVolume = 0; bus.groupSend.outputVolume = 0
        JarasEqualizer.setOutputMeteringEnabled(bus.controls, enabled: trackPeaks[id] != nil)
        trackBuses[id] = bus
        return bus
    }
    private var hardwareFormat: AVAudioFormat {
        // Every node in a prepared graph uses the same validated format. HAL
        // can change underneath us between calls; only device recovery reads
        // a fresh hardware snapshot and rebuilds the graph for it.
        preparedOutputFormat!
    }
    private func connectGroups() {
        let format = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.sampleRate, channels: 2)!
        let changed = trackBuses.filter {
            let row = tracks[$0.key]
            let parent = (row?.outputPatches.contains(.masterGroup) == true) ? row?.parentTrackID : nil
            return parent != groupConnections[$0.key]
        }
        // Disconnect old links first so regrouping cannot briefly form a cycle.
        for (_, bus) in changed { engine.disconnectNodeOutput(bus.groupSend) }
        for (id, bus) in changed {
            let row = tracks[id]
            let parent = (row?.outputPatches.contains(.masterGroup) == true) ? row?.parentTrackID : nil
            let destination = parent.flatMap { trackBuses[$0]?.mix } ?? masterBus
            engine.connect(bus.groupSend, to: destination, fromBus: 0, toBus: destination.nextAvailableInputBus, format: format)
            groupConnections[id] = parent
        }
    }

    private func connectTracks() {
        var next: Set<TrackConnection> = []
        for row in tracks.values {
            for destination in row.routing?.transmitters.compactMap({ $0 }) ?? [] { next.insert(TrackConnection(source: row.id, destination: destination)) }
            for source in row.routing?.receives.compactMap({ $0 }) ?? [] { next.insert(TrackConnection(source: source, destination: row.id)) }
        }
        next = next.filter {
            guard trackBuses[$0.source] != nil, trackBuses[$0.destination] != nil else { return false }
            let source = tracks[$0.source]
            return source?.parentTrackID != $0.destination || (source?.outputPatches.contains(.masterGroup) != true)
        }
        let changed = Set(trackConnections.symmetricDifference(next).map(\.source))
        guard !changed.isEmpty else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.sampleRate, channels: 2)!
        for id in changed { if let bus = trackBuses[id] { engine.disconnectNodeOutput(bus.internalSend) } }
        for id in changed {
            guard let bus = trackBuses[id] else { continue }
            var destinations: [AVAudioConnectionPoint] = []
            for edge in next where edge.source == id {
                if let target = trackBuses[edge.destination] { destinations.append(AVAudioConnectionPoint(node: target.mix, bus: target.mix.nextAvailableInputBus)) }
            }
            bus.internalSend.outputVolume = destinations.isEmpty ? 0 : 1
            if destinations.isEmpty { destinations = [AVAudioConnectionPoint(node: masterBus, bus: masterBus.nextAvailableInputBus)] }
            engine.connect(bus.internalSend, to: destinations, fromBus: 0, format: format)
        }
        trackConnections = next
    }
    func previewRouting(_ routes: [UUID: TrackRouting]) {
        for (id, routing) in routes { tracks[id]?.routing = routing }
        connectTracks()
    }
    private func configureMaster() throws {
        guard !masterConfigured else { return }
        engine.mainMixerNode.outputVolume = 0
        let output: AVAudioFormat
        #if os(iOS)
        if let mobileOutput {
            let session = AVAudioSession.sharedInstance()
            _ = try mobileOutput.configure(withSampleRate: session.sampleRate, channels: AVAudioChannelCount(session.outputNumberOfChannels))
        }
        #endif
        output = try JarasAudioOutputConnection.connect(engine)
        preparedOutputFormat = output
        engine.mainMixerNode.outputVolume = licenseAllowed && outputAllowed ? 1 : 0
        if realtime {
            if !deviceSilenceAttached { engine.attach(deviceSilence); deviceSilenceAttached = true }
            engine.connect(deviceSilence, to: engine.mainMixerNode, fromBus: 0, toBus: engine.mainMixerNode.nextAvailableInputBus, format: hardwareFormat)
        }
        engine.attach(masterBus); engine.attach(masterGain); engine.attach(masterChannelMode)
        let format = AVAudioFormat(standardFormatWithSampleRate: output.sampleRate, channels: 2)!
        if realtime {
            let generator = JarasMetronomeGenerator(format: format)
            engine.attach(generator.node)
            engine.attach(metronomeRoute)
            JarasChannelRouter.setRenderEnabled(metronomeRoute, enabled: renderEnabled)
            engine.connect(generator.node, to: metronomeRoute, format: format)
            engine.connect(metronomeRoute, to: engine.mainMixerNode, fromBus: 0, toBus: engine.mainMixerNode.nextAvailableInputBus, format: hardwareFormat)
            configureRoutes([metronomeRoute], patches: [MetronomeSettings.shared.output])
            generator.setEnabled(MetronomeSettings.shared.enabled)
            metronome = generator
            MetronomeSettings.shared.changed = { [weak self] in self?.refreshMetronome() }
        }
        masterEffects.mediaDirectory = directory
        masterEffects.attach(to: engine, input: masterBus, format: format)
        engine.connect(masterEffects.output, to: masterChannelMode, format: format)
        engine.connect(masterChannelMode, to: masterGain, format: format)
        for route in masterRoutes {
            JarasChannelRouter.setRenderEnabled(route, enabled: !realtime || renderEnabled)
            engine.attach(route); engine.connect(route, to: engine.mainMixerNode, fromBus: 0, toBus: engine.mainMixerNode.nextAvailableInputBus, format: hardwareFormat)
        }
        engine.connect(masterGain, to: masterRoutes.map { AVAudioConnectionPoint(node: $0, bus: 0) }, fromBus: 0, format: format)
        for (index, route) in masterRoutes.enumerated() {
            JarasChannelRouter.configure(route, first: index == 0 ? 1 : -1, count: 2)
            JarasChannelRouter.setInputMeteringEnabled(route, enabled: index == 0)
        }
        masterConfigured = true
    }
    var onPeakLimit: ((UUID) -> Void)?
    var onOutputDisconnected: (() -> Void)?
    var onError: (Error) -> Void = { _ in }
    private var suspendedEffectChains: [NativeEffectsChain] = []
    #if os(iOS)
    private var mobileHardwareStop: MobileAudioHardwareStop?
    /// Let an in-flight ML prediction return on its worker before admitting a
    /// replacement session. The main thread stays available during this wait.
    func waitForSuspendedProcessors() async throws {
        if let pending = mobileHardwareStop {
            do { try await pending.wait() }
            catch is CancellationError { throw CancellationError() }
            catch {
                throw ProjectError.invalid(JarasLocalization.string("Audio device is unavailable. Reconnect it or choose an output in Settings."))
            }
            if mobileHardwareStop === pending {
                mobileHardwareStop = nil
                finishDeviceSuspension()
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while suspendedEffectChains.contains(where: { $0.stemSeparatorWorkerRunning }) {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                throw ProjectError.invalid(JarasLocalization.string("CatStem is still finishing its previous session. Try again shortly."))
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    #endif
    func startDeviceSession() throws {
        guard realtime else { return }
        deviceSessionActive = true
        #if os(iOS)
        if mobileOutput != nil {
            AudioDeviceSettings.shared.deviceChanged = {
                AudioDeviceSettings.shared.mobileSessionEvent?(.routeChanged(outputRemoved: false))
            }
        } else {
            AudioDeviceSettings.shared.deviceChanged = { [weak self] in self?.scheduleDeviceRecovery() }
        }
        #else
        AudioDeviceSettings.shared.deviceChanged = { [weak self] in self?.scheduleDeviceRecovery() }
        #endif
        // Retain the device-health clock even if a route is temporarily absent
        // at launch. It can recover the saved output when HAL finishes binding.
        defer { startMeterClock() }
        guard outputAllowed else { return }
        #if os(macOS)
        if usesSelectedHardware { try requireSelectedOutput() }
        #endif
        if masterConfigured && outputFormatChanged {
            // These processors belong to the graph being replaced. Their
            // workers have drained; only the rebuilt chains should resume.
            suspendedEffectChains.removeAll()
            try reconfigureDevice()
        }
        try configureMaster()
        for effects in suspendedEffectChains { effects.resumeStemSeparator() }
        suspendedEffectChains.removeAll()
        try prepareDevice()
    }
    /// Suspend the hardware session without discarding the opened project or
    /// its decoded media. Switching to Remote cannot leave a health timer that
    /// silently restarts local playback behind the remote interface.
    func suspendDeviceSession() {
        deviceSessionActive = false
        deviceRecovery?.cancel(); deviceRecovery = nil
        meterTimer?.invalidate(); meterTimer = nil
        #if os(iOS)
        if usesSelectedHardware {
            setGraphRenderEnabled(false)
            mobileOutput?.gate()
            if mobileHardwareStop == nil {
                let hardware = engine
                let output = mobileOutput
                mobileHardwareStop = MobileAudioHardwareStop { output?.stop(); hardware.stop() }
            }
            return
        }
        #endif
        engine.stop()
        finishDeviceSuspension()
    }
    private func finishDeviceSuspension() {
        // The hardware may already have lost its render format. Stop pulls
        // before resetting players, detaching monitoring or stopping workers.
        var chains = [masterEffects] + trackBuses.values.map(\.effects)
        chains += voices.values.compactMap(\.effects)
        chains += idleVoices.values.flatMap { $0 }.compactMap(\.effects)
        chains += effectTails.values.compactMap { $0.voice.effects }
        chains += retiredVoices.compactMap(\.effects) + boundaryTails.compactMap { $0.0.effects }
        chains += midiTakeVoices.values.map(\.effects) + retiredMIDITakeVoices.map(\.effects)
        var seen = Set(suspendedEffectChains.map(ObjectIdentifier.init))
        for chain in chains where chain.stemSeparatorWorkerRunning && seen.insert(ObjectIdentifier(chain)).inserted {
            suspendedEffectChains.append(chain)
        }
        suspendedEffectChains.forEach { $0.stopStemSeparator() }
        releaseMIDINotes()
        armedMIDIRecordingTracks = []
        setArmedInstrumentTracks([])
        stop()
        engine.stop()
        if let deviceActivity { ProcessInfo.processInfo.endActivity(deviceActivity); self.deviceActivity = nil }
    }
    private func startEngineIfNeeded() throws {
        guard outputAllowed else { return }
        if engine.isRunning {
            try mobileOutput?.start()
            #if os(macOS)
            if usesSelectedHardware { try requireSelectedOutput() }
            #endif
            return
        }
        #if os(macOS)
        if usesSelectedHardware { try requireSelectedOutput() }
        #endif
        // prepare/start can resolve the system's default route again. Keep
        // output silent until its physical device is confirmed after both.
        engine.mainMixerNode.outputVolume = 0
        do {
            engine.prepare()
            #if os(macOS)
            if usesSelectedHardware { try requireSelectedOutput() }
            #endif
            try engine.start()
            try mobileOutput?.start()
            #if os(macOS)
            if usesSelectedHardware { try requireSelectedOutput() }
            #endif
            engine.mainMixerNode.outputVolume = licenseAllowed && outputAllowed ? 1 : 0
        } catch {
            engine.mainMixerNode.outputVolume = 0; engine.stop()
            throw error
        }
    }
    private func prepareDevice() throws {
        guard outputAllowed else { return }
        _ = engine.mainMixerNode
        try startEngineIfNeeded()
        if realtime {
            deviceSessionActive = true
            #if os(macOS)
            if deviceActivity == nil, !engine.isInManualRenderingMode {
                deviceActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "CatLive realtime audio")
            }
            #endif
        }
        startMeterClock()
    }
    private func startMeterClock() {
        guard realtime else { return }
        #if os(iOS)
        guard !usesSelectedHardware || AudioDeviceSettings.shared.localSessionEnabled else { return }
        #endif
        let active = transportWasRunning || instrumentRenderPending || !inputMonitors.isEmpty
        if !active { resetIdleMeterLevels() }
        guard meterTimer == nil || meterTimerActive != active else { return }
        meterTimer?.invalidate()
        meterTimerActive = active
        let timer = Timer(timeInterval: active ? 1.0 / 30.0 : 1.0, repeats: true) { [weak self] _ in
            // Foundation timer callbacks are not Swift executor jobs. Hop explicitly
            // instead of asking assumeIsolated to inspect the callback's executor.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.maintainDeviceSession()
                self.pollMeters()
            }
        }
        timer.tolerance = active ? 0.003 : 0.1; meterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func maintainDeviceSession() {
        guard deviceSessionActive, realtime else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDeviceHealthCheck >= 1 else { return }
        lastDeviceHealthCheck = now
        guard outputAllowed, deviceRecovery == nil else { return }
        #if os(macOS)
        if usesSelectedHardware, !AudioDeviceSettings.shared.outputDeviceIsBound {
            scheduleDeviceRecovery()
            return
        }
        #endif
        if !engine.isRunning { scheduleDeviceRecovery() }
    }
    func effects(for target: UUID?) -> NativeEffectsChain? {
        guard masterConfigured else { return nil }
        guard let target else { return masterEffects }
        if tracks[target] != nil, let track = trackBuses[target] { return track.effects }
        let fragments = clipFragments[target] ?? [target]
        for fragment in fragments {
            for head in 0...2 {
                let key = VoiceKey(clip: fragment, head: head)
                if let chain = voices[key]?.effects ?? effectTails[key]?.voice.effects ?? midiTakeVoices[key]?.effects { return chain }
            }
        }
        for fragment in fragments {
            guard let index = clipIndices[fragment] else { continue }
            let (track, clip) = clips[index]
            if let voice = idleVoices[track]?.first(where: { $0.clip.id == fragment }) { return voice.effects }
            guard let source = clip.audioFile else { continue }
            do {
                // An item FX editor can be opened away from the transport. Keep
                // its unscheduled voice in the normal pool so Play adopts the
                // same plugin instance, without rendering it while stopped.
                let voice = try takeVoice(track: track, clip: clip, file: audioFile(source))
                JarasVoiceGain.setRenderEnabled(voice.gain, enabled: false)
                idleVoices[track, default: []].append(voice)
                return voice.effects
            } catch { onError(error); return nil }
        }
        #if os(macOS)
        if let source = midiTakeSources[target], let voice = preparedMIDITakeVoice(for: VoiceKey(clip: target, head: 0), track: source.track) {
            voice.effects.apply(source.clip.fx ?? emptyFX)
            return voice.effects
        }
        #endif
        return nil
    }
    func observeEffect(_ target: UUID?, effect: String, active: Bool) {
        let key = target?.uuidString ?? "master"
        if active { analysisEffects[key, default: []].insert(effect) }
        else { analysisEffects[key]?.remove(effect) }
        let observed = analysisEffects[key] ?? []
        if !active { scheduleMIDITakeCleanup() }
        if target == nil || target.flatMap({ trackBuses[$0] }) != nil {
            effects(for: target)?.observe(observed)
        } else if let target {
            for fragment in clipFragments[target] ?? [target] {
                analysisEffects[fragment.uuidString] = observed
                for head in 0...2 {
                    let voiceKey = VoiceKey(clip: fragment, head: head)
                    voices[voiceKey]?.effects?.observe(observed)
                    midiTakeVoices[voiceKey]?.effects.observe(observed)
                    effectTails[voiceKey]?.voice.effects?.observe(observed)
                }
                if let index = clipIndices[fragment] {
                    for voice in idleVoices[clips[index].0] ?? [] where voice.clip.id == fragment { voice.effects?.observe(observed) }
                }
            }
        }
    }
    func spectrumFrame(_ track: UUID?, effect: String) -> Data? { effects(for: track)?.spectrum(effect) }
    func eqSpectrumFrames(_ target: UUID?, effect: String = "EQ") -> [EQAnalysisFrame] {
        if target == nil || target.flatMap({ trackBuses[$0] }) != nil {
            return effects(for: target)?.eqSpectrumFrame(effect).map { [$0] } ?? []
        }
        guard let target else { return [] }
        var frames: [EQAnalysisFrame] = []
        for head in 0...2 {
            let key = VoiceKey(clip: target, head: head)
            if let frame = voices[key]?.effects?.eqSpectrumFrame(effect) { frames.append(frame) }
            if let frame = effectTails[key]?.voice.effects?.eqSpectrumFrame(effect) { frames.append(frame) }
        }
        return frames
    }
    func effectSampleError(_ target: UUID?, effect: String) -> String? { effects(for: target)?.sampleErrors[effect] }
    func effectPeaks(_ track: UUID?, effect: String) -> [Float] { effects(for: track)?.effectPeaks(effect) ?? [0,0,0,0] }
    func compressorPeaks(for target: UUID?) -> [Float] { effects(for: target)?.compressorPeaks() ?? [0,0,0,0] }
    func meter(for id: UUID) -> TrackMeterLevel {
        if let meter = meters[id] { return meter }
        let meter = TrackMeterLevel(); meters[id] = meter; return meter
    }
    func stop() {
        stopMIDISequences()
        midiPlanRevision = nil
        for click in clickGenerators { click.configurePosition(0, hostTime: mach_absolute_time(), running: false, loopStart: 0, loopEnd: 0, sampleTime: .nan) }
        metronome?.configurePosition(0, hostTime: mach_absolute_time(), running: false, loopStart: 0, loopEnd: 0, sampleTime: .nan)
        cancelVoicePreparation()
        if realtime {
            for route in masterRoutes { JarasChannelRouter.beginStopFade(route) }
            for bus in trackBuses.values { for route in bus.hardware { JarasChannelRouter.beginStopFade(route) } }
            for route in timecodeRoutes { JarasChannelRouter.beginStopFade(route) }
        }
        timecodeGenerator?.configurePosition(0, end: 0, hostTime: mach_absolute_time(), rate: 30, mode: "", running: false, destination: 0)
        timecodeAnchor = nil
        releaseMIDINotes()
        transportWasRunning = false
        // Silence every active source before touching effect state or idle caches.
        for voice in voices.values { voice.player.volume = 0 }
        for tail in effectTails.values { JarasVoiceGain.setDecibels(tail.voice.gain, decibels: -96) }
        for key in Array(voices.keys) { remove(key) }
        for voice in retiredVoices { recycle(voice) }
        retiredVoices.removeAll()
        for tail in effectTails.values { recycle(tail.voice) }; effectTails.removeAll()
        for pooled in idleVoices.values {
            for voice in pooled {
                voice.player.stop()
                JarasVoiceGain.setRenderEnabled(voice.gain, enabled: false)
                voice.stretch.auAudioUnit.reset()
                voice.rateClock.auAudioUnit.reset()
                voiceClockAnchors[ObjectIdentifier(voice.player)] = nil
            }
        }
        resetEffectTails()
        instrumentRenderPending = !armedInstrumentTracks.isEmpty
        setGraphRenderEnabled(instrumentRenderPending)
        if !realtime {
            // Stop releases the converters' render resources but retains the
            // manual sample counter. Reset it as well: the next Play's players
            // and converter clocks must all begin on the same timeline.
            engine.stop()
            engine.reset()
        }
        preparedJump = nil
        appliedJumpBoundaries.removeAll(keepingCapacity: true)
        for (voice, _) in boundaryTails { recycle(voice) }; boundaryTails.removeAll()
        lastPosition.removeAll(); headAudioClock.removeAll()
        for meter in meters.values { meter.reset() }
        drainNativeMeterPeaks()
        masterMeter.reset(); _ = peaks.takePeak(masterSlot); _ = peaks.takePeak(masterSlot + 1)
        for bank in trackPeaks.values { _ = bank.takePeak(0); _ = bank.takePeak(1) }
        lastMeterUpdate = 0
        if deviceSessionActive { startMeterClock() }
    }
    func prepareForClosing() {
        #if os(iOS)
        // A timed-out HAL stop is still owned by its worker. Do not acquire
        // that same engine lock from a project-close/UI callback.
        guard mobileHardwareStop == nil else { return }
        #endif
        deviceSessionActive = false
        deviceRecovery?.cancel(); deviceRecovery = nil
        meterTimer?.invalidate(); meterTimer = nil
        configureGraph(directory: nil, resetProject: true, prepareMaster: false)
        // Route recovery retains suspended chains for reuse. A closed project
        // must release the drained chains instead of resuming its old effects.
        suspendedEffectChains.removeAll { !$0.stemSeparatorWorkerRunning }
        if let deviceActivity { ProcessInfo.processInfo.endActivity(deviceActivity); self.deviceActivity = nil }
        if deviceSilenceAttached { engine.detach(deviceSilence); deviceSilenceAttached = false }
    }
    private func resetEffectTails() {
        for bus in trackBuses.values { bus.effects.resetTails() }
        masterEffects.resetTails()
    }
    private func cancelVoicePreparation() {
        voicePreparation?.cancel(); voicePreparation = nil; preparationKey = nil
    }
    private func discardIdleVoices() {
        cancelVoicePreparation()
        for pooled in idleVoices.values { for voice in pooled { detach(voice) } }
        idleVoices.removeAll(); suspendedVoiceOutputs.removeAll()
    }
    private func recycle(_ voice: Voice) {
        var voice = voice
        restoreItemAutomation(&voice)
        // A deleted track cannot reuse its item pool. Detaching also cancels
        // item-owned model workers rather than retaining them until project close.
        guard tracks[voice.track] != nil else { detach(voice); return }
        voiceClockAnchors[ObjectIdentifier(voice.player)] = nil
        voice.player.volume = 0
        voice.player.stop()
        voice.stretch.auAudioUnit.reset()
        voice.rateClock.auAudioUnit.reset()
        voice.effects?.resetTails()
        voice.gain.auAudioUnit.reset()
        JarasVoiceGain.setRenderEnabled(voice.gain, enabled: false)
        JarasVoiceGain.setDecibels(voice.gain, decibels: Double(-96))
        // A mixer format converter can retain PCM after a stopped source.
        // Release just this connection so neither an ended item nor Sub Play
        // leaks buffered sound. Keep the processors ready for reuse.
        if let bus = trackBuses[voice.track], !voice.file.processingFormat.isEqual(bus.mix.outputFormat(forBus: 0)),
           suspendedVoiceOutputs.insert(ObjectIdentifier(voice.gain)).inserted {
            engine.disconnectNodeOutput(voice.gain)
        }
        idleVoices[voice.track, default: []].append(voice)
    }
    private func audioFile(_ audio: AudioFile) throws -> AVAudioFile {
        if let file = files[audio.path] { return file }
        guard let directory else { throw ProjectError.invalid("No project media directory") }
        let file = try AudioFileRead.openMedia(directory.appendingPathComponent(audio.path))
        files[audio.path] = file
        return file
    }
    private func makeVoice(track: UUID, clip: AudioClip, file: AVAudioFile) throws -> Voice {
        // Each player owns its reader; scheduling overlapping copies must not share a mutable file cursor.
        let playbackFile = try AVAudioFile(forReading: file.url)
        let player = AVAudioPlayerNode(), gain = JarasVoiceGain.makeNode(), stretch = AVAudioUnitTimePitch()
        let rateClock = AVAudioUnitVarispeed()
        // Rate conversion may request more input frames than the device's
        // output block. Reserve the upstream capacity before allocating the
        // live graph so a BPM edit cannot exceed a processor's default slice.
        for node in [player, stretch, rateClock, gain] as [AVAudioNode] {
            node.auAudioUnit.maximumFramesToRender = 8192
        }
        player.volume = 0
        let pitch = clipPitches[clip.id] ?? 0
        let usesStretch = !realtime || allowsTempoChanges || abs(clip.audioRate - 1) >= 0.000001 || abs(pitch) >= 0.000001
        configureStretch(stretch, clock: rateClock, rate: Float(clip.audioRate), pitch: pitch); stretch.overlap = 8
        engine.attach(player); engine.attach(gain); engine.attach(stretch); engine.attach(rateClock)
        let bus = trackBus(for: track).input(for: clip)
        let inputBus = availableInputBus(track: track, node: bus)
        if usesStretch {
            engine.connect(player, to: stretch, format: file.processingFormat)
            engine.connect(stretch, to: rateClock, format: file.processingFormat)
        }
        var voice = Voice(player: player, gain: gain, stretch: stretch, rateClock: rateClock, pitch: pitch, usesStretch: usesStretch, track: track, clip: clip, file: playbackFile)
        voice.mixInputBus = inputBus
        applyClipFX(clip.fx ?? emptyFX, to: &voice)
        engine.connect(gain, to: bus, fromBus: 0, toBus: inputBus, format: file.processingFormat)
        return voice
    }
    private func availableInputBus(track: UUID, node: AVAudioMixerNode) -> AVAudioNodeBus {
        let occupied = Set(voices.values.filter { $0.track == track }.map(\.mixInputBus) +
                           effectTails.values.filter { $0.voice.track == track }.map { $0.voice.mixInputBus } +
                           (idleVoices[track] ?? []).map(\.mixInputBus) + retiredVoices.filter { $0.track == track }.map(\.mixInputBus) + boundaryTails.filter { $0.0.track == track }.map { $0.0.mixInputBus })
        var inputBus: AVAudioNodeBus = 1
        while occupied.contains(inputBus) || engine.inputConnectionPoint(for: node, inputBus: inputBus) != nil { inputBus += 1 }
        return inputBus
    }
    private func takeVoice(track: UUID, clip: AudioClip, file: AVAudioFile) throws -> Voice {
        let pool = idleVoices[track] ?? []
        func matches(_ voice: Voice) -> Bool {
            (voice.clip.frozenMIDI == true) == (clip.frozenMIDI == true) &&
                abs(voice.clip.audioRate - clip.audioRate) < 0.000001 &&
                abs(voice.pitch - (clipPitches[clip.id] ?? 0)) < 0.000001 &&
                voice.file.processingFormat.isEqual(file.processingFormat) &&
                voice.usesStretch == (!realtime || allowsTempoChanges || abs(clip.audioRate - 1) >= 0.000001 || abs(clipPitches[clip.id] ?? 0) >= 0.000001)
        }
        let preferred = pool.firstIndex { $0.clip.id == clip.id && matches($0) }
        let reusable = pool.firstIndex { matches($0) && analysisEffects[$0.clip.id.uuidString]?.isEmpty != false }
        if let index = preferred ?? reusable {
            // A cached AVAudioFile can outlive a removed/disconnected media
            // path. Open its replacement before taking ownership of the pooled
            // graph; a failed read must leave all attached nodes tracked so
            // they can be reused or released when the project closes.
            let playbackFile = pool[index].file.url == file.url ? pool[index].file : try AVAudioFile(forReading: file.url)
            var voice = idleVoices[track]!.remove(at: index)
            // A pooled player's render gate may have been suspended for an
            // entire song. Format converters can then report a fresh sample
            // count with an old host timestamp. Rebase this silent player before
            // scheduling; extrapolating that stale pair delays PCM by the idle time.
            if voice.player.isPlaying {
                voice.player.stop()
                voiceClockAnchors[ObjectIdentifier(voice.player)] = nil
                voice.stretch.auAudioUnit.reset()
                voice.rateClock.auAudioUnit.reset()
                voice.effects?.resetTails()
            }
            voice.file = playbackFile
            voice.clip = clip
            voice.scheduledOnset = nil
            JarasVoiceGain.setRenderEnabled(voice.gain, enabled: true)
            voice.effects?.setPlaybackBoundary()
            if suspendedVoiceOutputs.remove(ObjectIdentifier(voice.gain)) != nil {
                engine.connect(voice.gain, to: trackBus(for: track).input(for: clip), fromBus: 0, toBus: voice.mixInputBus, format: file.processingFormat)
            }
            voice.effects?.observe(analysisEffects[clip.id.uuidString] ?? [])
            applyClipFX(clip.fx ?? emptyFX, to: &voice)
            return voice
        }
        return try makeVoice(track: track, clip: clip, file: file)
    }
    private func prepareIdleVoices(position: Double, revision: UInt64) {
        let key = "\(songID?.uuidString ?? "")/\(revision)/\(position)"
        guard preparationKey != key else { return }
        cancelVoicePreparation(); preparationKey = key
        if onsetPreparationKey != key { preparedOnsets.removeAll(keepingCapacity: true); onsetPreparationKey = key }
        let upcoming = clips.filter { $0.1.startTime <= position + 2 && $0.1.startTime + $0.1.duration > position && $0.1.audioFile != nil }
        voicePreparation = Task { @MainActor [weak self] in
            var required: [UUID: [(AVAudioFormat, Double)]] = [:]
            for (track, clip) in upcoming {
                // Let pointer/key events run between preparing individual sources.
                await Task.yield()
                guard !Task.isCancelled, let self, self.preparationKey == key,
                      self.latestPlayback?.snapshot.transport.playing != true,
                      self.latestPlayback?.snapshot.transport.subPlay.playing != true else { return }
                do {
                    let source = clip.audioFile!
                    if clip.isProjectionMedia && self.silentVideoFiles.contains(source.path) { continue }
                    let file: AVAudioFile
                    do { file = try self.audioFile(source) }
                    catch {
                        guard clip.isProjectionMedia, AudioFileRead.isVideoWithoutAudio(error) else { throw error }
                        self.silentVideoFiles.insert(source.path)
                        continue
                    }
                    required[track, default: []].append((file.processingFormat, clip.audioRate))
                    let count = required[track]!.filter { $0.0.isEqual(file.processingFormat) && abs($0.1 - clip.audioRate) < 0.000001 }.count
                    let ready = self.idleVoices[track, default: []].filter { $0.file.processingFormat.isEqual(file.processingFormat) && abs($0.clip.audioRate - clip.audioRate) < 0.000001 }.count
                    let rate = file.processingFormat.sampleRate
                    var first = AVAudioFramePosition((clip.sourceOffset + max(0, position - clip.startTime) * clip.audioRate) * rate)
                    var available = file.length - first
                    if let length = clip.loopLength {
                        let loopFirst = max(0, AVAudioFramePosition((clip.loopStart ?? 0) * rate))
                        let loopEnd = min(file.length, loopFirst + AVAudioFramePosition(length * rate))
                        let frames = loopEnd - loopFirst
                        if frames > 0 {
                            first = loopFirst + ((first - loopFirst) % frames + frames) % frames
                            available = loopEnd - first
                        }
                    }
                    if first >= 0, available > 0 {
                        let frames = AVAudioFrameCount(min(available, Int64(ceil(rate * 0.1))))
                        let onsetKey = OnsetKey(path: file.url.path, first: first, frames: frames)
                        self.preparedOnsets[onsetKey] = try self.readOnset(file: file, first: first, frames: frames)
                    }
                    if ready < count {
                        let voice = try self.makeVoice(track: track, clip: clip, file: file)
                        JarasVoiceGain.setRenderEnabled(voice.gain, enabled: false)
                        self.idleVoices[track, default: []].append(voice)
                        #if os(iOS)
                        try self.warmIdleVoice(voice)
                        #endif
                    }
                } catch { self.onError(error); return }
            }
            // Keep decoded onsets and attached voices ready, but do not loop
            // silence through every stretcher while stopped. takeVoice/warmPlayer
            // starts and rebases only the players actually needed for playback.
        }
    }
    #if os(iOS)
    /// Exercise cold decoder/stretch/FX paths while stopped, before the first
    /// audible deadline. A finite silent buffer bounds CPU work and never touches
    /// the source file, transport position or the user's first transient.
    private func warmIdleVoice(_ voice: Voice) throws {
        guard realtime, deviceSessionActive, outputAllowed, !transportWasRunning else { return }
        // Opening a document rebuilds and stops the engine. Do not postpone its
        // first render until Play or the one-second device-health timer.
        try startEngineIfNeeded()
        guard let silence = AVAudioPCMBuffer(pcmFormat: voice.file.processingFormat, frameCapacity: 4096) else { return }
        silence.frameLength = silence.frameCapacity
        for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        voice.player.volume = 0
        JarasVoiceGain.setRenderEnabled(voice.gain, enabled: true)
        voice.player.scheduleBuffer(silence)
        voice.player.play()
        let player = voice.player, track = voice.track
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self,
                  let idle = self.idleVoices[track]?.first(where: { $0.player === player }) else { return }
            // A Play may already have taken this voice. Only pooled sources can
            // be silenced here; never change an active player's render gate.
            JarasVoiceGain.setRenderEnabled(idle.gain, enabled: false)
        }
    }
    #endif
    static func requiresSourceClockRenewal(source: AVAudioTime?, reference: AVAudioTime?, latency: Double) -> Bool {
        guard let source, let reference, source.isHostTimeValid, reference.isHostTimeValid,
              reference.hostTime > source.hostTime else { return false }
        let age = AVAudioTime.seconds(forHostTime: reference.hostTime - source.hostTime)
        return age > max(0.1, max(0, latency) + 0.05)
    }
    private func warmPlayer(_ voice: Voice) {
        JarasVoiceGain.setRenderEnabled(voice.gain, enabled: true)
        guard let silence = AVAudioPCMBuffer(pcmFormat: voice.file.processingFormat, frameCapacity: 256) else { return }
        silence.frameLength = 256
        for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        voice.player.scheduleBuffer(silence, at: nil, options: .loops)
        voice.player.play()
        if let node = voice.player.lastRenderTime, node.isSampleTimeValid || node.isHostTimeValid, let player = voice.player.playerTime(forNodeTime: node) {
            voiceClockAnchors[ObjectIdentifier(voice.player)] = (node, player)
        }
    }
    private func detach(_ voice: Voice) {
        voiceClockAnchors[ObjectIdentifier(voice.player)] = nil
        suspendedVoiceOutputs.remove(ObjectIdentifier(voice.gain))
        voice.player.stop()
        voice.effects?.detach(from: engine)
        engine.detach(voice.player); engine.detach(voice.gain); engine.detach(voice.stretch); engine.detach(voice.rateClock)
    }
    private func remove(_ key: VoiceKey, keepingTailAt position: Double? = nil) {
        guard let voice = voices.removeValue(forKey: key) else { return }
        if let position, voice.clip.muted != true, voice.clip.fxBypassed != true, (voice.clip.gain ?? 1) > 0,
           let settings = voice.clip.fx, voice.effects != nil {
            var duration = voice.effects?.triggerTailDuration ?? 0
            if settings.delayEnabled && settings.delayMix > 0 {
                let repeats = settings.feedback <= 0 ? 1 : max(1, ceil(log(0.001) / log(settings.feedback / 100)))
                duration += min(120, settings.delayTime * repeats)
            }
            if settings.reverbEnabled && settings.reverbMix > 0 { duration += settings.reverbDecay * 2 }
            if duration > 0 {
                voice.player.stop()
                if let old = effectTails.removeValue(forKey: key) { recycle(old.voice) }
                effectTails[key] = EffectTail(voice: voice, until: position + duration)
                return
            }
        }
        recycle(voice)
    }
    /// Tempo sections of one continuous file share the decoder and stretcher.
    /// Only their rate changes; there is no new preroll at an internal marker.
    private func advanceContiguousVoices(head: Int, position: Double) {
        for originalKey in Array(voices.keys) where originalKey.head == head {
            guard var voice = voices[originalKey], voice.continuousSource else { continue }
            var key = originalKey
            while voice.clip.startTime + voice.clip.duration <= position,
                  let next = contiguousNext[key.clip], let index = clipIndices[next], voices[VoiceKey(clip: next, head: head)] == nil {
                let successor = clips[index].1
                voices[key] = nil; key = VoiceKey(clip: next, head: head)
                voice.clip = successor
                voice.pitch = clipPitches[next] ?? voice.pitch
                configureStretch(voice.stretch, clock: voice.rateClock, rate: Float(successor.audioRate), pitch: voice.pitch)
                setVoice(voice, for: key)
            }
        }
    }
    private func hasContinuousPredecessor(_ clip: UUID, head: Int) -> Bool {
        var previous = contiguousPrevious[clip]
        while let id = previous {
            if voices[VoiceKey(clip: id, head: head)]?.continuousSource == true { return true }
            previous = contiguousPrevious[id]
        }
        return false
    }
    private func clearEffectTails(head: Int) {
        for key in Array(effectTails.keys) where key.head == head {
            if let tail = effectTails.removeValue(forKey: key) { recycle(tail.voice) }
        }
    }
    private func applyNormalization(to voice: inout Voice) {
        voice.effects?.updateItemFade(voice.clip)
        voice.effects?.setSourceGain(voice.clip.normalizationGain ?? 1)
        voice.effects?.setSourceChannelMode(voice.clip.channelMode ?? 0)
        voice.effects?.setSourcePolarity(voice.clip.phaseInverted == true)
        voice.player.pan = Float(voice.clip.pan ?? 0)
    }
    func previewItemPhase(_ id: UUID, inverted: Bool) { previewItemMix(id, inverted: inverted, pan: nil) }
    func previewItemPan(_ id: UUID, pan: Double) {
        guard pan.isFinite else { return }
        previewItemMix(id, inverted: nil, pan: min(1, max(-1, pan)))
    }
    private func previewItemMix(_ id: UUID, inverted: Bool?, pan: Double?) {
        func update(_ clip: inout AudioClip) {
            if let inverted { clip.phaseInverted = inverted }
            if let pan { clip.pan = pan == 0 ? nil : pan }
        }
        previewMIDITake(id, change: update)
        for fragment in clipFragments[id] ?? [id] {
            if let index = clipIndices[fragment] { update(&clips[index].1) }
            for head in 0...2 {
                let key = VoiceKey(clip: fragment, head: head)
                if var voice = voices[key] { update(&voice.clip); applyNormalization(to: &voice); setVoice(voice, for: key) }
                if var tail = effectTails[key] { update(&tail.voice.clip); applyNormalization(to: &tail.voice); effectTails[key] = tail }
            }
        }
    }
    func previewItemFade(_ id: UUID, fadeIn: Bool, seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        previewFade(id) { clip in
            if fadeIn { clip.fadeIn = seconds } else { clip.fadeOut = seconds }
        }
    }
    func previewItemFadeShape(_ id: UUID, fadeIn: Bool, curvature: Double, sCurve: Double) {
        previewFade(id) { clip in
            if fadeIn { clip.fadeInCurve = curvature; clip.fadeInSCurve = sCurve }
            else { clip.fadeOutCurve = curvature; clip.fadeOutSCurve = sCurve }
        }
    }
    private func previewFade(_ id: UUID, change: (inout AudioClip) -> Void) {
        previewMIDITake(id, refreshNotes: true, change: change)
        for fragment in clipFragments[id] ?? [id] {
            if let index = clipIndices[fragment] { change(&clips[index].1) }
            for head in 0...2 {
                let key = VoiceKey(clip: fragment, head: head)
                if var voice = voices[key] {
                    change(&voice.clip)
                    voice.effects?.updateItemFade(voice.clip); setVoice(voice, for: key)
                }
            }
        }
    }
    func previewItemNormalization(_ id: UUID, gain: Double) {
        guard gain.isFinite, gain >= 0 else { return }
        for fragment in clipFragments[id] ?? [id] {
            if let index = clipIndices[fragment] { clips[index].1.normalizationGain = gain }
            for head in 0...2 {
                let key = VoiceKey(clip: fragment, head: head)
                if var voice = voices[key] { voice.clip.normalizationGain = gain; applyNormalization(to: &voice); setVoice(voice, for: key) }
                if var tail = effectTails[key] { tail.voice.clip.normalizationGain = gain; applyNormalization(to: &tail.voice); effectTails[key] = tail }
            }
        }
    }
    func previewItemChannelMode(_ id: UUID, mode: Int) {
        guard (0...3).contains(mode) else { return }
        for fragment in clipFragments[id] ?? [id] {
            if let index = clipIndices[fragment] { clips[index].1.channelMode = mode }
            for head in 0...2 {
                let key = VoiceKey(clip: fragment, head: head)
                if var voice = voices[key] { voice.clip.channelMode = mode; applyNormalization(to: &voice); setVoice(voice, for: key) }
                if var tail = effectTails[key] { tail.voice.clip.channelMode = mode; applyNormalization(to: &tail.voice); effectTails[key] = tail }
            }
        }
    }
    private func applyClipFX(_ settings: NativeFXSettings, to voice: inout Voice) {
        // Prepare the complete path before scheduling PCM. AVAudioEngine graph
        // rewiring can invalidate an active player's scheduled file segments.
        if voice.effects == nil {
            let chain = NativeEffectsChain(reorderable: false)
            chain.mediaDirectory = directory
            chain.attach(to: engine, input: voice.usesStretch ? voice.rateClock : voice.player, format: voice.file.processingFormat,
                         destinations: [AVAudioConnectionPoint(node: voice.gain, bus: 0)])
            chain.observe(analysisEffects[voice.clip.id.uuidString] ?? [])
            voice.effects = chain
        }
        var effective = settings
        if voice.clip.fxBypassed == true {
            effective.eqEnabled = false; effective.compressorEnabled = false; effective.limiterEnabled = false
            effective.delayEnabled = false; effective.reverbEnabled = false; effective.pitchEnabled = false
            for key in effective.effectKeys { effective.setEnabled(key, enabled: false) }
            if let plugins = effective.externalPlugins { effective.externalPlugins = plugins.map { var plugin = $0; plugin.bypassed = true; return plugin } }
        }
        voice.effects?.apply(effective)
        applyNormalization(to: &voice)
    }
    func previewClipFXBypass(_ id: UUID, bypassed: Bool) {
        previewMIDITake(id) { $0.fxBypassed = bypassed }
        appliedJumpBoundaries.removeAll(keepingCapacity: true)
        for fragment in clipFragments[id] ?? [id] { previewClipFXBypassFragment(fragment, bypassed: bypassed) }
    }
    private func previewClipFXBypassFragment(_ id: UUID, bypassed: Bool) {
        if let index = clipIndices[id] { clips[index].1.fxBypassed = bypassed }
        previewIdleClipFX(id) { $0.fxBypassed = bypassed }
        for head in 0...2 {
            let key = VoiceKey(clip: id, head: head)
            if var voice = voices[key], voice.clip.fxBypassed != bypassed {
                voice.clip.fxBypassed = bypassed
                applyClipFX(voice.clip.fx ?? emptyFX, to: &voice); setVoice(voice, for: key)
            }
            if var tail = effectTails[key], tail.voice.clip.fxBypassed != bypassed {
                tail.voice.clip.fxBypassed = bypassed
                applyClipFX(tail.voice.clip.fx ?? emptyFX, to: &tail.voice); effectTails[key] = tail
            }
        }
    }
    func previewClipFX(_ id: UUID, settings: NativeFXSettings) {
        do { try settings.validateForClip() } catch { return }
        previewMIDITake(id) { $0.fx = settings }
        appliedJumpBoundaries.removeAll(keepingCapacity: true)
        for fragment in clipFragments[id] ?? [id] { previewClipFXFragment(fragment, settings: settings) }
    }
    private func previewClipFXFragment(_ id: UUID, settings: NativeFXSettings) {
        do { try settings.validateForClip() } catch { return }
        if let index = clipIndices[id] { clips[index].1.fx = settings }
        previewIdleClipFX(id) { $0.fx = settings }
        for head in 0...2 {
            let key = VoiceKey(clip: id, head: head)
            if var voice = voices[key] {
                voice.clip.fx = settings; applyClipFX(settings, to: &voice); setVoice(voice, for: key)
            }
            if var tail = effectTails[key] {
                tail.voice.clip.fx = settings; applyClipFX(settings, to: &tail.voice); effectTails[key] = tail
            }
        }
    }
    private func previewIdleClipFX(_ id: UUID, change: (inout AudioClip) -> Void) {
        guard let index = clipIndices[id] else { return }
        let track = clips[index].0
        guard var pool = idleVoices[track] else { return }
        for index in pool.indices where pool[index].clip.id == id {
            change(&pool[index].clip)
            applyClipFX(pool[index].clip.fx ?? emptyFX, to: &pool[index])
        }
        idleVoices[track] = pool
    }
    var onRecordingFXChanged: ((UUID, NativeFXSettings) -> Void)?
    func previewFX(_ track: UUID?, settings: NativeFXSettings) {
        if let track, tracks[track] == nil { return }
        appliedJumpBoundaries.removeAll(keepingCapacity: true)
        if let track {

for (key, sampler) in samplers where key.track == track && !settings.isEnabled(key.effect) { sampler.silence() }

        }
        if let track { tracks[track]?.fx = settings; trackBuses[track]?.effects.apply(settings) }
        else { masterFXSettings = settings; masterEffects.apply(settings) }
        if let track { onRecordingFXChanged?(track, settings) }
        applyLevels()
        #if os(macOS)
        if let error = effects(for: track)?.externalError { onError(error) }
        #endif
    }
    #if os(macOS)
    /// Save captured the live node; mirror its serialized state in the playback
    /// descriptions without touching processors, connections, clocks or jumps.
    func rememberCapturedPluginState(track: UUID?, clip: UUID?, plugin: ExternalPlugin, source: AVAudioUnitEffect) {
        func remember(_ settings: inout NativeFXSettings) {
            guard let index = settings.externalPlugins?.firstIndex(where: { $0.id == plugin.id }) else { return }
            settings.externalPlugins?[index].componentState = plugin.componentState
            settings.externalPlugins?[index].controllerState = plugin.controllerState
        }
        func remember(_ settings: inout NativeFXSettings?) {
            guard var value = settings else { return }; remember(&value); settings = value
        }
        guard let clip else {
            if let track {
                if var row = tracks[track] { remember(&row.fx); tracks[track] = row }
                trackBuses[track]?.effects.rememberCapturedPluginState(plugin, source: source)
            } else {
                remember(&masterFXSettings)
                masterEffects.rememberCapturedPluginState(plugin, source: source)
            }
            return
        }
        for id in Array(tracks.keys) {
            if let index = tracks[id]?.clips.firstIndex(where: { $0.id == clip }), var row = tracks[id] {
                remember(&row.clips[index].fx); tracks[id] = row; break
            }
        }
        if var value = midiTakeSources[clip] { remember(&value.clip.fx); midiTakeSources[clip] = value }
        if var plan = midiTakePlans[clip] {
            remember(&plan.clip.fx)
            for index in plan.segments.indices { remember(&plan.segments[index].fx) }
            midiTakePlans[clip] = plan
        }
        let fragments = Set(clipFragments[clip] ?? [clip])
        for fragment in fragments {
            if let index = clipIndices[fragment] { remember(&clips[index].1.fx) }
            for head in 0...2 {
                let key = VoiceKey(clip: fragment, head: head)
                if var voice = voices[key] {
                    remember(&voice.clip.fx); voice.effects?.rememberCapturedPluginState(plugin, source: source)
                    setVoice(voice, for: key)
                }
                if var tail = effectTails[key] {
                    remember(&tail.voice.clip.fx); tail.voice.effects?.rememberCapturedPluginState(plugin, source: source)
                    effectTails[key] = tail
                }
                midiTakeVoices[key]?.effects.rememberCapturedPluginState(plugin, source: source)
            }
        }
        for id in Array(idleVoices.keys) {
            guard var pool = idleVoices[id] else { continue }
            for index in pool.indices where fragments.contains(pool[index].clip.id) {
                remember(&pool[index].clip.fx); pool[index].effects?.rememberCapturedPluginState(plugin, source: source)
            }
            idleVoices[id] = pool
        }
        for index in retiredVoices.indices where fragments.contains(retiredVoices[index].clip.id) {
            remember(&retiredVoices[index].clip.fx); retiredVoices[index].effects?.rememberCapturedPluginState(plugin, source: source)
        }
        for index in boundaryTails.indices where fragments.contains(boundaryTails[index].0.clip.id) {
            remember(&boundaryTails[index].0.clip.fx); boundaryTails[index].0.effects?.rememberCapturedPluginState(plugin, source: source)
        }
        for voice in retiredMIDITakeVoices where fragments.contains(voice.clipID) {
            voice.effects.rememberCapturedPluginState(plugin, source: source)
        }
    }
    #endif
    func previewItemGain(_ id: UUID, gain: Double) {
        guard gain.isFinite, gain >= 0 else { return }
        previewMIDITake(id) { $0.gain = gain }
        for fragment in clipFragments[id] ?? [id] { previewItemGainFragment(fragment, gain: gain) }
    }
    private func previewItemGainFragment(_ id: UUID, gain: Double) {
        guard gain.isFinite, gain >= 0 else { return }
        if let index = clipIndices[id], clips[index].1.gain != gain { clips[index].1.gain = gain }
        let decibels = Float(min(24, max(-96, 20 * log10(max(0.0000001, gain)))))
        // Include the prepared jump voice as well as Play and Sub Play. Lookup keeps each
        // pointer motion independent of the number of other playing tracks.
        for head in 0...2 {
            let key = VoiceKey(clip: id, head: head)
            if var voice = voices[key], voice.clip.gain != gain {
                voice.clip.gain = gain
                voice.player.volume = gain <= 0 || voice.clip.muted == true ? 0 : 1
                JarasVoiceGain.setDecibels(voice.gain, decibels: Double(voice.clip.muted == true || gain <= 0 ? -96 : decibels))
                setVoice(voice, for: key)
            }
            if var tail = effectTails[key], tail.voice.clip.gain != gain {
                tail.voice.clip.gain = gain
                JarasVoiceGain.setDecibels(tail.voice.gain, decibels: Double(tail.voice.clip.muted == true || gain <= 0 ? -96 : decibels))
                effectTails[key] = tail
            }
        }
    }
    func previewVolume(_ track: UUID?, gain: Double) {
        guard gain.isFinite, gain >= 0 else { return }
        if let track, track == timecodeTrackID {
            let original = latestPlayback?.snapshot.project.songs.flatMap(\.tracks).first { $0.id == track }?.volume ?? 1
            timecodePreviewGain = (gain, original)
            timecodeGenerator?.setGain(Float(effectiveLoopGain(track, manual: gain)) * (timecodePhaseInverted ? -1 : 1)); return
        }
        if let track {
            guard tracks[track] != nil else { return }
            tracks[track]?.volume = gain
            applyTrackGain(track)
        } else {
            master = gain
            applyMasterGain()
        }
    }
    func previewMasterPan(_ pan: Double) {
        masterPan = min(1, max(-1, pan))
        JarasEqualizer.setInputPan(masterChannelMode, pan: masterPan)
    }
    func previewPan(_ id: UUID, pan: Double) {
        tracks[id]?.pan = pan
        if let bus = trackBuses[id] { JarasEqualizer.setInputPan(bus.controls, pan: pan) }
    }
    func previewMute(_ id: UUID?, muted: Bool) {
        if let id {
            guard let track = tracks[id], track.mute != muted else { return }
            tracks[id]?.mute = muted; applyTrackGate(id)
        } else if masterMuted != muted {
            masterMuted = muted
            applyMasterGain()
        }
    }
    func previewPhase(_ id: UUID?, inverted: Bool) {
        if let id {
            if latestPlayback?.snapshot.project.songs.flatMap(\.tracks).contains(where: { $0.id == id && $0.kind == .timecode }) == true {
                timecodePhaseInverted = inverted
                let gain = timecodePreviewGain?.value ?? latestPlayback?.snapshot.project.songs.flatMap(\.tracks).first(where: { $0.id == id })?.volume ?? 1
                let effective = Float(effectiveLoopGain(id, manual: gain))
                timecodeGenerator?.setGain(inverted ? -effective : effective)
            } else {
                tracks[id]?.phaseInverted = inverted
                if let bus = trackBuses[id] { JarasEqualizer.setPolarity(bus.controls, inverted: inverted) }
            }
        }
    }
    func previewMasterMono(_ mono: Bool) {
        masterMono = mono
        JarasEqualizer.setInputChannelMode(masterChannelMode, mode: mono ? 3 : 0)
    }
    func previewMasterSolo(_ solo: Bool) {
        guard masterSolo != solo else { return }
        masterSolo = solo
        // Gate only the hardware branches. Track meters, group buses and
        // transmit/receive paths remain active, without rescheduling audio.
        for (id, bus) in trackBuses {
            if let track = tracks[id] { applyTrackRoutes(track, bus: bus) }
        }
        if let latestPlayback { updateTimecode(latestPlayback.0) }
    }
    func previewSolo(_ id: UUID, solo: Bool) {
        guard let track = tracks[id], track.solo != solo else { return }
        let previous = soloAudibleTracks
        tracks[id]?.solo = solo; refreshSoloEligibility()
        // Only gates whose solo eligibility changed need an audio-unit write.
        for track in tracks.keys where (previous?.contains(track) ?? true) != (soloAudibleTracks?.contains(track) ?? true) {
            applyTrackGate(track)
        }
    }
    func previewClipMute(_ id: UUID, muted: Bool) {
        for fragment in clipFragments[id] ?? [id] { previewClipMuteFragment(fragment, muted: muted) }
    }
    private func previewClipMuteFragment(_ id: UUID, muted: Bool) {
        if let index = clipIndices[id] { clips[index].1.muted = muted }
        for head in 0...2 {
            let key = VoiceKey(clip: id, head: head)
            if var voice = voices[key], voice.clip.muted != muted {
                voice.clip.muted = muted
                let gain = voice.clip.gain ?? 1
                voice.player.volume = muted || gain <= 0 ? 0 : 1
                JarasVoiceGain.setDecibels(voice.gain, decibels: Double(muted || gain <= 0 ? -96 : Float(min(24, max(-96, 20 * log10(max(0.0000001, gain)))))))
                setVoice(voice, for: key)
            }
            if var tail = effectTails[key], tail.voice.clip.muted != muted {
                tail.voice.clip.muted = muted
                let gain = tail.voice.clip.gain ?? 1
                JarasVoiceGain.setDecibels(tail.voice.gain, decibels: Double(muted || gain <= 0 ? -96 : Float(min(24, max(-96, 20 * log10(max(0.0000001, gain)))))))
                effectTails[key] = tail
            }
        }
    }
    func previewPatches(_ id: UUID?, patches: [OutputPatch]) {
        if let id {
            guard let track = tracks[id], patches.allSatisfy({ (try? $0.validate(allowMaster: true, allowGroup: track.parentTrackID != nil, allowNone: true)) != nil }) else { return }
            tracks[id]?.outputs = patches
            if let updated = tracks[id], let bus = trackBuses[id] { connectGroups(); connectTracks(); applyTrackRoutes(updated, bus: bus) }
        } else {
            guard patches.allSatisfy({ (try? $0.validate(allowMaster: false, allowNone: true)) != nil }) else { return }
            masterPatches = patches; applyMasterRoutes()
        }
    }
    func previewPatch(_ id: UUID?, patch: OutputPatch, slot: Int) {
        guard slot == 0 || slot == 1 else { return }
        var values = id.flatMap { tracks[$0]?.outputPatches } ?? masterPatches
        while values.count <= slot { values.append(.none) }
        values[slot] = patch; previewPatches(id, patches: values)
    }
    func previewMIDIInput(_ id: UUID, slot: Int) {
        guard (0...3).contains(slot), let track = tracks[id] else { return }
        let input: Int? = slot == 0 ? nil : slot
        guard track.midiInput != input else { return }
        releaseTrackMIDI(id)
        tracks[id]?.midiInput = input
    }
    func previewMIDIChannel(_ id: UUID, channel: Int) {
        guard (0...16).contains(channel), let track = tracks[id] else { return }
        let selected: Int? = channel == 0 ? nil : channel
        guard track.midiChannel != selected else { return }
        releaseTrackMIDI(id)
        tracks[id]?.midiChannel = selected
    }
    private func releaseTrackMIDI(_ id: UUID) {
        // Queue releases ahead of the new input, without flushing new notes.
        for channel in 0..<16 {
            let status = UInt8(0xb0 | channel)
            for controller: UInt8 in [120, 64] {

for (key, sampler) in samplers where key.track == id {
                    sampler.sendStatus(status, data1: controller, data2: 0)
                }

                #if os(macOS)
                trackBuses[id]?.effects.sendExternalMIDI(status: status, number: controller, value: 0)
                #endif
            }
        }
        InstrumentKeyboardState.shared.reset(track: id)
    }
    private func refreshSoloEligibility() {
        soloAudibleTracks = TrackHierarchy.soloAudibleTracks(Array(tracks.values))
    }
    private func updateLoopGainContext(song: Song, transport: TransportState, revision: UInt64) -> Set<UUID> {
        let rules = transport.multiLoop?.tracks ?? []
        let rebuild = loopGainPlanKey?.song != song.id || loopGainPlanKey?.revision != revision || loopGainPlanKey?.rules != rules
        guard rebuild || loopGainState != transport.multiLoop else { return [] }
        let previous = Set(loopGainPlan.internalRules.keys)
        if rebuild {
            loopGainPlan = MultiLoopGainPlan(loop: transport.multiLoop, tracks: song.tracks)
            loopGainPlanKey = (song.id, revision, rules)
        }
        loopGainState = transport.multiLoop
        return previous.union(loopGainPlan.internalRules.keys)
    }
    private func effectiveLoopGain(_ id: UUID, manual: Double) -> Double {
        // Resolve on the control thread using the original curve. Writing the
        // existing gain target preserves its interpolation and sample math.
        loopGainState?.gain(manual, rule: loopGainPlan.internalRules[id]) ?? manual
    }
    private func applyMasterGain() {
        let gain = effectiveLoopGain(MultiLoopTrack.masterID, manual: automationGain(MultiLoopTrack.masterID, manual: master))
        masterGain.globalGain = Float(min(12, max(-96, 20 * log10(max(0.0000001, gain)))))
        // Preserve the existing zero/mute gate before master FX as well as
        // the post-FX gain, including how effect tails behave at zero.
        masterBus.outputVolume = (automatedMix[MultiLoopTrack.masterID]?.mute ?? masterMuted) || gain <= 0 ? 0 : 1
    }
    private func applyTrackGain(_ id: UUID) {
        guard let track = tracks[id], let bus = trackBuses[id] else { return }
        let gain = effectiveLoopGain(id, manual: automationGain(id, manual: track.volume))
        let audible = !(automatedMix[id]?.mute ?? track.mute) && (soloAudibleTracks?.contains(id) ?? true) && gain > 0
        JarasEqualizer.setInputGain(bus.controls, gain: audible ? min(pow(10, 12.0 / 20), gain) : 0)
    }
    private func applyTrackGate(_ id: UUID) {
        guard let track = tracks[id], let bus = trackBuses[id] else { return }
        applyTrackGain(id)
        JarasEqualizer.setPolarity(bus.controls, inverted: track.phaseInverted == true)
    }
    private func configureRoutes(_ nodes: [AVAudioUnitEffect], patches: [OutputPatch]) {
        for node in nodes {
            let key = ObjectIdentifier(node)
            guard appliedRoutes[key] != patches else { continue }
            JarasChannelRouter.configurePatches(node, firsts: patches.map { NSNumber(value: $0.firstChannel) }, counts: patches.map { NSNumber(value: $0.channelCount) })
            appliedRoutes[key] = patches
        }
    }
    private func applyMasterRoutes() { configureRoutes(masterRoutes, patches: masterPatches) }
    private func applyTrackRoutes(_ track: Track, bus: TrackBus) {
        let outputs = track.outputPatches
        bus.masterSend.outputVolume = outputs.contains(.master) ? 1 : 0
        bus.groupSend.outputVolume = track.parentTrackID != nil && outputs.contains(.masterGroup) ? 1 : 0
        configureRoutes(bus.hardware, patches: masterSolo ? [] : outputs)
    }
    private func discardRetiredVoicesForDeletedTracks() {
        for voice in retiredVoices where tracks[voice.track] == nil { detach(voice) }
        retiredVoices.removeAll { tracks[$0.track] == nil }
        for (voice, _) in boundaryTails where tracks[voice.track] == nil { detach(voice) }
        boundaryTails.removeAll { tracks[$0.0.track] == nil }
        for key in Array(midiTakeVoices.keys) {
            guard let voice = midiTakeVoices[key], tracks[voice.track] == nil else { continue }
            midiTakeVoices[key] = nil
            voice.effects.detach(from: engine)
            engine.detach(voice.source); engine.detach(voice.controls); engine.detach(voice.gain)
        }
        for voice in retiredMIDITakeVoices where tracks[voice.track] == nil {
            voice.effects.detach(from: engine)
            engine.detach(voice.source); engine.detach(voice.controls); engine.detach(voice.gain)
        }
        retiredMIDITakeVoices.removeAll { tracks[$0.track] == nil }
    }
    private func applyLevels() {
        syncInstruments()
        masterEffects.apply(masterFXSettings)
        JarasEqualizer.setInputPan(masterChannelMode, pan: masterPan)
        JarasEqualizer.setPolarity(masterChannelMode, inverted: false)
        JarasEqualizer.setInputChannelMode(masterChannelMode, mode: masterMono ? 3 : 0)
        applyMasterGain()
        applyMasterRoutes(); refreshSoloEligibility()
        for (id, bus) in trackBuses {
            guard let track = tracks[id] else {
                if retiredTrackEffects.insert(id).inserted {
                    JarasEqualizer.setInputGain(bus.controls, gain: 0)
                    bus.effects.observe([])
                    bus.effects.apply(NativeFXSettings())
                    bus.effects.resetTails()
                }
                continue
            }
            retiredTrackEffects.remove(id)
            bus.effects.apply(track.fx ?? NativeFXSettings())
            applyTrackGate(id)
            JarasEqualizer.setInputPan(bus.controls, pan: track.pan)
            applyTrackRoutes(track, bus: bus)
        }

for (key,sampler) in samplers {
            guard let track = tracks[key.track], let fx = track.fx else { continue }
            let voice = fx.settings(for: key.effect)
            let settings = voice.instrumentParameters ?? InstrumentLibrary.parameters(voice.instrumentID)
            let controllerVolume = settings.controllers?.volume ?? 0
            sampler.setGain(!fx.isEnabled(key.effect) || controllerVolume <= -96 ? -96 : settings.gain + controllerVolume, pan: 0)
            sampler.setEnvelopeAttack(settings.attack, hold: settings.hold, decay: settings.decay, sustain: settings.sustain, release: settings.release)
            let category = InstrumentLibrary.category(voice.instrumentID)
            let controllers = settings.controllers ?? InstrumentLibrary.controllers(category)
            sampler.setControllersModulation(controllers.modulation, pitchBend: controllers.pitchBend)
            let velocity = settings.velocity ?? InstrumentVelocityParameters()
            let cutoff = settings.cutoff ?? InstrumentCutoffParameters()
            sampler.setPerformanceMonophonic(controllers.monophonic ?? (category == .lead), drums: category == .drum, velocityCurve: Int32(velocity.curve.index))
            sampler.setFilterCutoff(cutoff.frequency, velocityMinimum: velocity.cutoffMinimum, attack: cutoff.attack, hold: cutoff.hold, decay: cutoff.decay, sustain: cutoff.sustain, release: cutoff.release, depth: cutoff.depth)
        }

        for voice in voices.values {
            let muted = voice.clip.muted == true
            let linear = voice.clip.gain ?? 1
            voice.player.volume = muted || linear <= 0 ? 0 : 1
            voice.player.pan = Float(voice.clip.pan ?? 0)
            JarasVoiceGain.setDecibels(voice.gain, decibels: Double(muted || linear <= 0 ? -96 : Float(min(24, max(-96, 20 * log10(max(0.0000001, linear)))))))
        }
    }
    private func syncInstruments() {
        var wanted: [InstrumentVoiceKey: String] = [:]
        for (track, row) in tracks {
            guard let fx = row.fx else { continue }
            for key in fx.instrumentKeys {
                wanted[InstrumentVoiceKey(track: track, effect: key)] = fx.settings(for: key).instrumentID
            }
        }
        for id in Set(samplers.keys).union(instrumentRequests.keys) where wanted[id] == nil {
            instrumentRequests[id] = nil; instrumentNames[id] = nil
            if let sampler = samplers.removeValue(forKey: id) { sampler.silence(); engine.detach(sampler.node) }
        }
        for (id, name) in wanted {
            guard instrumentNames[id] != name, let (url,_) = instrumentFile?(name) else { continue }
            instrumentNames[id] = name
            let request = UUID(), generation = instrumentGeneration
            let sampleRate = masterBus.outputFormat(forBus: 0).sampleRate
            instrumentRequests[id] = request
            // Decode the SF2 on a worker queue, then attach its prepared node
            // on the main queue alongside other audio graph changes.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { PreparedSoundFont(try JarasSoundFont(url: url, sampleRate: sampleRate)) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.instrumentGeneration == generation, self.instrumentRequests[id] == request else { return }
                    do {
                        let sampler = try result.get().unit
                        if let old = self.samplers.removeValue(forKey: id) { self.engine.detach(old.node) }
                        self.engine.attach(sampler.node)
                        let bus = self.trackBus(for: id.track)
                        let format = sampler.node.outputFormat(forBus: 0)
                        guard let instrument = bus.effects.instrumentInput(for: id.effect) else { self.engine.detach(sampler.node); self.instrumentRequests[id] = nil; self.instrumentNames[id] = nil; return }
                        self.engine.connect(sampler.node, to: instrument, fromBus: 0, toBus: 1, format: format)
                        self.samplers[id] = sampler
                        sampler.setSequenceNotes(self.midiPlans[id.track] ?? [])
                        if let playback = self.latestPlayback { self.updateMIDISequenceClocks(playback.snapshot.transport) }
                        self.instrumentRequests[id] = nil
                        self.applyLevels()
                        if !self.engine.isRunning { try self.prepareDevice() }
                    } catch {
                        self.instrumentRequests[id] = nil; self.instrumentNames[id] = nil
                        self.onError(error)
                    }
                }
            }
        }

}
    func isInstrumentReady(_ track: UUID) -> Bool {
        guard let fx = tracks[track]?.fx, !fx.instrumentKeys.isEmpty else { return false }
        return fx.instrumentKeys.allSatisfy {
            let key = InstrumentVoiceKey(track: track, effect: $0)
            return samplers[key] != nil && instrumentRequests[key] == nil
        }

}
    private var midiPlanRevision: UInt64?
    private var midiPlanSong: UUID?
    private var midiPlans: [UUID: [[String: Double]]] = [:]
    private struct MIDITakePlan {
        let track: UUID
        var clip: AudioClip
        var segments: [AudioClip]
        let notes: [[String: Double]]
    }
    @MainActor private final class MIDITakeVoice {
        let source = AVAudioSourceNode { silent, _, _, buffers in
            silent.pointee = true
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
        let effects = NativeEffectsChain()
        let controls = JarasEqualizer.makeNode()
        let gain = JarasVoiceGain.makeNode()
        let track: UUID
        var clipID: UUID
        var lastUsed: UInt64 = 0
        var running = false
        var planRevision: UInt64?
        var planSong: UUID?
        var reportedError: String?
        var externalBase: [String: (String, UInt32, Double)] = [:]
        var externalValues: [String: Double] = [:]
        init(track: UUID, clip: UUID) { self.track = track; self.clipID = clip }
    }
    private var midiTakePlans: [UUID: MIDITakePlan] = [:]
    private var midiTakeSources: [UUID: (track: UUID, clip: AudioClip)] = [:]
    private var midiTakeVoices: [VoiceKey: MIDITakeVoice] = [:]
    private var retiredMIDITakeVoices: [MIDITakeVoice] = []
    private var midiTakeCacheTick: UInt64 = 0
    private var midiTakeCleanup: Task<Void, Never>?
    private func pruneMIDITakeCache() {
        // Keep a small warm cache. An explicitly open take FX editor owns its
        // instance until it closes, and running/nearby heads cannot be evicted.
        let idle = (Array(midiTakeVoices.values) + retiredMIDITakeVoices).filter {
            !$0.running && (analysisEffects[$0.clipID.uuidString]?.isEmpty != false)
        }.sorted { $0.lastUsed < $1.lastUsed }
        let count = max(0, idle.count - 8)
        guard count > 0 else { return }
        for voice in idle.prefix(count) {
            for key in Array(midiTakeVoices.keys) where midiTakeVoices[key] === voice { midiTakeVoices[key] = nil }
            retiredMIDITakeVoices.removeAll { $0 === voice }
            voice.effects.detach(from: engine)
            engine.detach(voice.source); engine.detach(voice.controls); engine.detach(voice.gain)
        }
    }
    private func scheduleMIDITakeCleanup() {
        guard midiTakeVoices.count + retiredMIDITakeVoices.count > 8 else { return }
        if !realtime { pruneMIDITakeCache(); return }
        guard midiTakeCleanup == nil else { return }
        midiTakeCleanup = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.midiTakeCleanup = nil
            self.pruneMIDITakeCache()
        }
    }
    private func discardMIDITakeVoices() {
        midiTakeCleanup?.cancel(); midiTakeCleanup = nil
        for voice in Array(midiTakeVoices.values) + retiredMIDITakeVoices {
            voice.effects.detach(from: engine)
            engine.detach(voice.source); engine.detach(voice.controls); engine.detach(voice.gain)
        }
        midiTakeVoices.removeAll(); retiredMIDITakeVoices.removeAll(); midiTakePlans.removeAll(); midiTakeSources.removeAll()
    }
    private func preparedMIDITakeVoice(for key: VoiceKey, track: UUID) -> MIDITakeVoice? {
        if let voice = midiTakeVoices[key], voice.track == track { return voice }
        guard let bus = trackBuses[track] else { return nil }
        if let old = midiTakeVoices.removeValue(forKey: key) {
            old.effects.detach(from: engine); engine.detach(old.source); engine.detach(old.controls); engine.detach(old.gain)
        }
        let voice: MIDITakeVoice
        if let index = retiredMIDITakeVoices.firstIndex(where: { $0.track == track && analysisEffects[$0.clipID.uuidString]?.isEmpty != false }) {
            voice = retiredMIDITakeVoices.remove(at: index)
            voice.planRevision = nil; voice.planSong = nil
            #if os(macOS)
            for (plugin, parameter, value) in voice.externalBase.values {
                if let node = voice.effects.externalNode(plugin) { JarasVST3.setParameter(node, identifier: plugin, parameter: parameter, value: value) }
            }
            #endif
            voice.externalBase.removeAll(keepingCapacity: true)
            voice.externalValues.removeAll(keepingCapacity: true)
            voice.reportedError = nil
        } else {
            voice = MIDITakeVoice(track: track, clip: key.clip)
            engine.attach(voice.source); engine.attach(voice.controls); engine.attach(voice.gain)
            voice.effects.mediaDirectory = directory
            voice.effects.attach(to: engine, input: voice.source, format: hardwareFormat,
                destinations: [AVAudioConnectionPoint(node: voice.controls, bus: 0)])
            engine.connect(voice.controls, to: voice.gain, format: hardwareFormat)
            engine.connect(voice.gain, to: bus.mix, fromBus: 0, toBus: bus.mix.nextAvailableInputBus, format: hardwareFormat)
        }
        // Editors may prepare an item before Play. No generator/DSP is pulled
        // until a transport head actually activates it.
        JarasVoiceGain.setRenderEnabled(voice.gain, enabled: false)
        voice.clipID = key.clip
        voice.effects.observe(analysisEffects[key.clip.uuidString] ?? [])
        midiTakeVoices[key] = voice
        return voice
    }
    private func previewMIDITake(_ id: UUID, refreshNotes: Bool = false, change: (inout AudioClip) -> Void) {
        guard var source = midiTakeSources[id] else { return }
        let wasInstrument = source.clip.hasTakeInstrument
        change(&source.clip); midiTakeSources[id] = source
        if var plan = midiTakePlans[id] {
            change(&plan.clip)
            for index in plan.segments.indices { change(&plan.segments[index]) }
            midiTakePlans[id] = source.clip.hasTakeInstrument ? plan : nil
        }
        if let song = latestPlayback?.snapshot.project.songs.first(where: { $0.id == midiPlanSong }) {
            if source.clip.hasTakeInstrument && (midiTakePlans[id] == nil || refreshNotes) {
                var notes = source.clip; notes.gain = 1
                midiTakePlans[id] = MIDITakePlan(track: source.track, clip: source.clip,
                    segments: song.tempoAudioSegments(source.clip), notes: song.midiPlaybackNotes(in: notes).map(\.sequenceValues))
            }
            if wasInstrument != source.clip.hasTakeInstrument || refreshNotes {
                let notes = midiTakeSources.values.filter { $0.track == source.track && !$0.clip.hasTakeInstrument }
                    .flatMap { song.midiPlaybackNotes(in: $0.clip) }.map(\.sequenceValues)
                midiPlans[source.track] = notes

for (key, sampler) in samplers where key.track == source.track { sampler.setSequenceNotes(notes) }

                #if os(macOS)
                trackBuses[source.track]?.effects.setMIDISequence(notes)
                #endif
            }
        }
        for head in 0..<2 {
            guard let voice = midiTakeVoices[VoiceKey(clip: id, head: head)] else { continue }
            let transport = latestPlayback?.snapshot.transport
            let position = head == 0 ? transport?.position ?? source.clip.startTime : transport?.subPlay.position ?? source.clip.startTime
            let clip = midiTakePlans[id]?.segments.last(where: { $0.startTime <= position }) ?? source.clip
            let values = clip.automatedValues(at: position)
            #if os(macOS)
            if refreshNotes, let notes = midiTakePlans[id]?.notes { voice.effects.setMIDISequence(notes) }
            #endif
            voice.effects.apply(values.fx)
            JarasEqualizer.setInputPan(voice.controls, pan: values.pan)
            JarasEqualizer.setPolarity(voice.controls, inverted: clip.phaseInverted == true)
            JarasVoiceGain.setDecibels(voice.gain, decibels: values.muted || values.gain <= 0 ? -96 : min(24, max(-96, 20*log10(values.gain))))
            if !source.clip.hasTakeInstrument {
                #if os(macOS)
                voice.effects.setMIDISequenceClock(head: 0, position: 0, clock: 0, running: false, loopStart: 0, loopEnd: 0)
                voice.effects.silenceExternal()
                #endif
                JarasVoiceGain.setRenderEnabled(voice.gain, enabled: false); voice.running = false
            }
        }
    }
    private func updateMIDITakes(_ transport: TransportState, song: Song, preserveHeld: Bool) {
#if os(macOS)
        #if os(macOS)
        guard !midiTakePlans.isEmpty || !midiTakeVoices.isEmpty else { return }
        var active = Set<VoiceKey>(), cacheChanged = false
        midiTakeCacheTick &+= 1
        for head in 0..<2 {
            let running = head == 0 ? transport.playing : transport.subPlay.playing
            guard running else { continue }
            let position = head == 0 ? transport.position : transport.subPlay.position
            let host = audioHostTime(position: position, head: head) ?? mach_absolute_time()
            let clock = realtime ? AVAudioTime.seconds(forHostTime: host) : Double(engine.manualRenderingSampleTime) / hardwareFormat.sampleRate
            let loopStart = head == 0 && transport.loop.enabled ? transport.loop.start ?? 0 : 0
            let loopEnd = head == 0 && transport.loop.enabled ? transport.loop.end ?? 0 : 0
            for (id, plan) in midiTakePlans {
                let clip = plan.clip, key = VoiceKey(clip: id, head: head)
                // Prepare only nearby takes. Ended/idle instances keep their
                // graph but the gate stops all upstream plugin render work.
                guard song.playbackScope(transport, head: head).allows(song.playbackItemStart(clip)),
                      clip.muted != true, clip.startTime < position + 2,
                      clip.startTime + clip.duration > position - 1 else { continue }
                let existed = midiTakeVoices[key] != nil
                guard let voice = preparedMIDITakeVoice(for: key, track: plan.track) else { continue }
                if !existed { cacheChanged = true }
                voice.lastUsed = midiTakeCacheTick
                active.insert(key)
                let segment = plan.segments.last(where: { $0.startTime <= position }) ?? clip
                let values = segment.automatedValues(at: min(clip.startTime + clip.duration, max(clip.startTime, position)))
                voice.effects.apply(values.fx)
                let error = voice.effects.externalError?.localizedDescription
                if error != voice.reportedError {
                    voice.reportedError = error
                    if let failure = voice.effects.externalError { onError(failure) }
                }
                let section = song.tempoSection(at: position)
                voice.effects.externalTransport(position: position, tempo: section.bpm,
                    beats: Int32(section.beats), unit: Int32(section.unit), playing: true)
                if voice.planRevision != midiPlanRevision || voice.planSong != midiPlanSong {
                    voice.effects.setMIDISequence(plan.notes, instrumentsOnly: true, preserveHeld: preserveHeld)
                    voice.planRevision = midiPlanRevision; voice.planSong = midiPlanSong
                }
                voice.effects.setMIDISequenceClock(head: 0, position: position, clock: clock, running: true, loopStart: loopStart, loopEnd: loopEnd)
                var externalActive = Set<String>()
                for entry in values.external {
                    guard let plugin = entry.target.plugin, let parameter = entry.target.parameter,
                          values.fx.externalPlugins?.contains(where: { $0.id == plugin && values.fx.inserted.contains($0.effectKey) }) == true,
                          let node = voice.effects.externalNode(plugin) else { continue }
                    let id = entry.target.key
                    externalActive.insert(id)
                    if voice.externalBase[id] == nil,
                       let original = JarasVST3.parameters(node, identifier: plugin).first(where: { ($0["id"] as? UInt32) == parameter })?["value"] as? Double {
                        voice.externalBase[id] = (plugin, parameter, original)
                    }
                    if voice.externalValues[id] != entry.value {
                        JarasVST3.setParameter(node, identifier: plugin, parameter: parameter, value: entry.value)
                        voice.externalValues[id] = entry.value
                    }
                }
                for id in Set(voice.externalBase.keys).subtracting(externalActive) {
                    if let (plugin, parameter, value) = voice.externalBase.removeValue(forKey: id), let node = voice.effects.externalNode(plugin) {
                        JarasVST3.setParameter(node, identifier: plugin, parameter: parameter, value: value)
                    }
                    voice.externalValues[id] = nil
                }
                JarasEqualizer.setInputPan(voice.controls, pan: values.pan)
                JarasEqualizer.setPolarity(voice.controls, inverted: clip.phaseInverted == true)
                JarasEqualizer.setInputChannelMode(voice.controls, mode: Int32(clip.channelMode ?? 0))
                JarasEqualizer.setInputGain(voice.controls, gain: clip.normalizationGain ?? 1)
                JarasEqualizer.setInputFade(voice.controls, fadeIn: 0, fadeOut: 0,
                    duration: clip.duration, position: position - clip.startTime,
                    hostTime: realtime ? host : 0, sampleTime: realtime ? 0 : Double(engine.manualRenderingSampleTime))
                JarasVoiceGain.setDecibels(voice.gain, decibels: values.muted || values.gain <= 0 ? -96 : min(24, max(-96, 20 * log10(values.gain))))
                JarasVoiceGain.setRenderEnabled(voice.gain, enabled: true)
                voice.running = true
            }
        }
        for (key, voice) in midiTakeVoices where !active.contains(key) && voice.running {
            voice.effects.setMIDISequenceClock(head: 0, position: 0, clock: 0, running: false, loopStart: 0, loopEnd: 0)
            voice.effects.silenceExternal(); voice.effects.resetTails()
            voice.effects.externalTransport(position: 0, tempo: song.bpm, beats: Int32(song.meterBeats), unit: Int32(song.meterUnit), playing: false)
            JarasVoiceGain.setRenderEnabled(voice.gain, enabled: false)
            voice.running = false
            cacheChanged = true
        }
        if cacheChanged { scheduleMIDITakeCleanup() }
        #endif

#endif
}
    private func prepareMIDISequences(song: Song) {
        var plans: [UUID: [[String: Double]]] = [:]
        midiTakePlans.removeAll(keepingCapacity: true)
        midiTakeSources.removeAll(keepingCapacity: true)
        for track in song.tracks where track.kind == .standard {
            let notes = track.clips.flatMap { clip -> [MIDIPlaybackNote] in
                guard clip.midi != nil else { return [] }
                midiTakeSources[clip.id] = (track.id, clip)
                if clip.hasTakeInstrument {
                    var source = clip; source.gain = 1
                    let notes = song.midiPlaybackNotes(in: source).map(\.sequenceValues)
                    midiTakePlans[clip.id] = MIDITakePlan(track: track.id, clip: clip, segments: song.tempoAudioSegments(clip), notes: notes)
                    return []
                }
                return song.midiPlaybackNotes(in: clip)
            }
            let values = notes.map { ["start": $0.start, "end": $0.end, "pitch": Double($0.pitch), "velocity": Double($0.velocity), "channel": Double($0.channel)] }
            plans[track.id] = values
            if midiPlans[track.id] != values {

for (key, sampler) in samplers where key.track == track.id { sampler.setSequenceNotes(values) }

            }
            #if os(macOS)
            trackBuses[track.id]?.effects.setMIDISequence(values)
            #endif
        }
        midiPlans = plans

}
    private func updateMIDISequenceClocks(_ transport: TransportState) {
        for head in 0..<2 {
            let position = head == 0 ? transport.position : transport.subPlay.position
            let running = head == 0 ? transport.playing : transport.subPlay.playing
            let host = audioHostTime(position: position, head: head) ?? mach_absolute_time()
            let clock = realtime ? AVAudioTime.seconds(forHostTime: host) : Double(engine.manualRenderingSampleTime) / hardwareFormat.sampleRate
            let start = head == 0 && transport.loop.enabled ? transport.loop.start ?? 0 : 0
            let end = head == 0 && transport.loop.enabled ? transport.loop.end ?? 0 : 0

for sampler in samplers.values { sampler.sequenceHead(Int32(head), position: position, clock: clock, running: running, loopStart: start, loopEnd: end) }

            #if os(macOS)
            for bus in trackBuses.values { bus.effects.setMIDISequenceClock(head: head, position: position, clock: clock, running: running, loopStart: start, loopEnd: end) }
            #endif
        }
    }
    private func stopMIDISequences() {
        for voice in midiTakeVoices.values {
            #if os(macOS)
            voice.effects.setMIDISequenceClock(head: 0, position: 0, clock: 0, running: false, loopStart: 0, loopEnd: 0)
            voice.effects.silenceExternal()
            voice.effects.externalTransport(position: 0, tempo: tempo ?? 120, beats: 4, unit: 4, playing: false)
            #endif
            voice.effects.resetTails(); voice.running = false
            JarasVoiceGain.setRenderEnabled(voice.gain, enabled: false)
        }
        scheduleMIDITakeCleanup()
        for head in 0..<2 {

for sampler in samplers.values { sampler.sequenceHead(Int32(head), position: 0, clock: 0, running: false, loopStart: 0, loopEnd: 0) }

            #if os(macOS)
            for bus in trackBuses.values { bus.effects.setMIDISequenceClock(head: head, position: 0, clock: 0, running: false, loopStart: 0, loopEnd: 0) }
            #endif
        }
    }
    private var virtualNoteTargets: [UInt8: [UUID: UInt8]] = [:]
    var onLiveKeyboardMIDI: ((UUID, UInt8, UInt8, UInt8) -> Void)?
    func releaseMIDINotes() {
        releaseKeyboardNotes()
        virtualNoteTargets.removeAll(); InstrumentKeyboardState.shared.reset()
        #if os(macOS)
        for bus in trackBuses.values { bus.effects.silenceExternal() }
        #endif

for sampler in samplers.values { sampler.silence() }

    }
    var midiSlotsProvider: () -> [Int32] = { AudioDeviceSettings.shared.midiSlots }
    func receiveMIDI(device: Int32,status: UInt8,number: UInt8,value: UInt8) {
        #if os(iOS)
        guard !usesSelectedHardware || (deviceSessionActive && outputAllowed) else { return }
        #endif
        let slots = midiSlotsProvider()
        for (id, row) in tracks {
            guard row.acceptsMIDI(status: status), let slot = row.midiInput, (1...3).contains(slot), slots.indices.contains(slot - 1), slots[slot - 1] == device,
                  armedInstrumentTracks.contains(id) || status & 0xf0 != 0x90 || value == 0 else { continue }
            InstrumentKeyboardState.shared.receive(track: id, source: device, status: status, number: number, value: value)
        }
        #if os(macOS)
        for (id, row) in tracks {
            guard row.acceptsMIDI(status: status), let slot = row.midiInput, (1...3).contains(slot), slots.indices.contains(slot-1), slots[slot-1] == device, let bus = trackBuses[id] else { continue }
            bus.effects.sendExternalMIDI(status: status, number: number, value: value)
        }
        #endif

for (key,sampler) in samplers {
            let id = key.track
            guard tracks[id]?.acceptsMIDI(status: status) == true, tracks[id]?.fx?.isEnabled(key.effect) == true, let slot = tracks[id]?.midiInput, (1...3).contains(slot), slots.indices.contains(slot-1), slots[slot-1] == device else { continue }
            guard armedInstrumentTracks.contains(id) || status & 0xf0 != 0x90 || value == 0 else { continue }
            sampler.sendStatus(status, data1: number, data2: value)
        }


}
    func playKeyboardNote(_ note: UInt8, velocity: UInt8 = 100) {
        #if os(iOS)
        guard !usesSelectedHardware || (deviceSessionActive && outputAllowed) else { return }
        #endif
        guard (21...108).contains(note) else { return }
        releaseKeyboardNote(note)
        let targets = armedInstrumentTracks.union(armedMIDIRecordingTracks).filter { tracks[$0]?.kind == .standard }
        let selected = max(0, min(16, UserDefaults.standard.integer(forKey: "jaras.keyboard.channel")))
        for id in targets {
            let channel = UInt8((selected == 0 ? max(1, tracks[id]?.midiChannel ?? 1) : selected) - 1)
            let status: UInt8 = 0x90 | channel
            guard tracks[id]?.acceptsMIDI(status: status) == true else { continue }
            virtualNoteTargets[note, default: [:]][id] = channel
            onLiveKeyboardMIDI?(id, status, note, velocity)
            #if os(macOS)
            trackBuses[id]?.effects.sendExternalMIDI(status: status, number: note, value: velocity)
            #endif

for (key, sampler) in samplers where key.track == id && tracks[id]?.fx?.isEnabled(key.effect) == true { sampler.sendStatus(status, data1: note, data2: velocity) }

            InstrumentKeyboardState.shared.receive(track: id, source: Int32.min, status: status, number: note, value: velocity)
        }

}
    func releaseKeyboardNote(_ note: UInt8) {
        for (id, channel) in virtualNoteTargets.removeValue(forKey: note) ?? [:] {
            let status: UInt8 = 0x80 | channel
            onLiveKeyboardMIDI?(id, status, note, 0)
            #if os(macOS)
            trackBuses[id]?.effects.sendExternalMIDI(status: status, number: note, value: 0)
            #endif

for (key, sampler) in samplers where key.track == id { sampler.sendStatus(status, data1: note, data2: 0) }

            InstrumentKeyboardState.shared.receive(track: id, source: Int32.min, status: status, number: note, value: 0)
        }
    }
    func releaseKeyboardNotes() { for note in Array(virtualNoteTargets.keys) { releaseKeyboardNote(note) } }
    // Only a few milliseconds are read on the scheduling thread. The remaining
    // file continues streaming through AVAudioPlayerNode, without a PCM copy.
    private func scheduleLoop(file: AVAudioFile, player: AVAudioPlayerNode, clip: AudioClip, from start: Double, until end: Double, onset: Bool, at playbackTime: AVAudioTime? = nil) throws -> Double {
        let prepared = try prepareLoop(file: file, player: player, clip: clip, from: start, until: end, onset: onset)
        prepared.command(playbackTime)
        return prepared.end
    }
    private func prepareLoop(file: AVAudioFile, player: AVAudioPlayerNode, clip: AudioClip, from start: Double, until end: Double, onset: Bool, rampSeek: Bool = true) throws -> (end: Double, command: @Sendable (AVAudioTime?) -> Void) {
        let rate = file.processingFormat.sampleRate
        let loopFirst = max(0, AVAudioFramePosition((clip.loopStart ?? 0) * rate))
        let loopEnd = min(file.length, loopFirst + AVAudioFramePosition((clip.loopLength ?? Double(file.length) / rate) * rate))
        let length = loopEnd - loopFirst
        guard length > 0 else { return (start, { _ in }) }
        var time = start
        var segments: [(first: AVAudioFramePosition, count: AVAudioFrameCount)] = []
        let limit = min(end, clip.startTime + clip.duration)
        while time < limit - 0.5 / rate / clip.audioRate && segments.count < 1024 {
            let elapsed = AVAudioFramePosition((((time - clip.startTime) * clip.audioRate + clip.sourceOffset) * rate).rounded())
            let first = loopFirst + ((elapsed - loopFirst) % length + length) % length
            let count = min(loopEnd - first, max(1, AVAudioFramePosition(((limit - time) * rate * clip.audioRate).rounded())), Int64(UInt32.max))
            segments.append((first, AVAudioFrameCount(count)))
            time += Double(count) / rate / clip.audioRate
        }
        let initial = try onset ? segments.first.map { try startCommand(file: file, player: player, first: $0.first, count: $0.count, rampSeek: rampSeek) } : nil
        let queued = initial == nil ? segments[...] : segments.dropFirst()
        return (time, { at in
            initial?(at)
            for segment in queued { player.scheduleSegment(file, startingFrame: segment.first, frameCount: segment.count, at: nil, completionHandler: nil) }
        })
    }
    private func readOnset(file: AVAudioFile, first: AVAudioFramePosition, frames: AVAudioFrameCount, rampSeek: Bool = true) throws -> AVAudioPCMBuffer {
        guard let onset = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw ProjectError.invalid("Could not prepare audio onset")
        }
        file.framePosition = first
        try file.read(into: onset, frameCount: frames)
        guard onset.frameLength > 0, let channels = onset.floatChannelData else {
            throw ProjectError.invalid("Could not read audio onset")
        }
        // A file's natural attack is already intentional PCM: a blanket ramp
        // erases short drum/click impulses. Ramp only a seek into existing audio.
        let length = !rampSeek || first == 0 ? 0 : min(Int(onset.frameLength), Int(ceil(file.processingFormat.sampleRate * 0.003)))
        for channel in 0..<Int(onset.format.channelCount) {
            for sample in 0..<length { channels[channel][sample * onset.stride] *= Float(sample) / Float(max(1, length - 1)) }
        }
        return onset
    }
    private func startCommand(file: AVAudioFile, player: AVAudioPlayerNode, first: AVAudioFramePosition, count: AVAudioFrameCount, rampSeek: Bool = true) throws -> @Sendable (AVAudioTime?) -> Void {
        let frames = min(count, AVAudioFrameCount(ceil(file.processingFormat.sampleRate * 0.1)))
        let key = OnsetKey(path: file.url.path, first: first, frames: frames)
        let onset = try rampSeek ? (preparedOnsets[key] ?? readOnset(file: file, first: first, frames: frames))
            : readOnset(file: file, first: first, frames: frames, rampSeek: false)
        return { playbackTime in
            let continuation: AVAudioTime?
            if let playbackTime, playbackTime.isSampleTimeValid {
                continuation = AVAudioTime(sampleTime: playbackTime.sampleTime + AVAudioFramePosition(onset.frameLength), atRate: playbackTime.sampleRate)
            } else { continuation = nil }
            player.scheduleBuffer(onset, at: playbackTime, options: .interrupts, completionHandler: nil)
            if count > onset.frameLength {
                player.scheduleSegment(file, startingFrame: first + AVAudioFramePosition(onset.frameLength), frameCount: count - onset.frameLength, at: continuation, completionHandler: nil)
            }
        }
    }
    func updateTimecode(_ snapshot: ShowSnapshot) {
        guard masterConfigured, outputAllowed, directory != nil,
              let song = snapshot.project.songs.first(where: { $0.id == snapshot.transport.songId }) else { return }
        updateTimecode(song: song, transport: snapshot.transport)
    }
    private func updateTimecode(song: Song, transport: TransportState) {
        guard let track = song.tracks.first(where: { $0.kind == .timecode }) else {
            if timecodeAnchor != nil {
                timecodeGenerator?.configurePosition(0, end: 0, hostTime: mach_absolute_time(), rate: 30, mode: "", running: false, destination: 0)
                timecodeAnchor = nil
            }
            return
        }
        if timecodeGenerator == nil {
            let format = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.sampleRate, channels: 2)!
            let generator = JarasTimecodeGenerator(format: format)
            let routes = [JarasChannelRouter.makeNode()]
            engine.attach(generator.node)
            for route in routes {
                JarasChannelRouter.setRenderEnabled(route, enabled: !realtime || renderEnabled)
                engine.attach(route); engine.connect(route, to: engine.mainMixerNode, fromBus: 0, toBus: engine.mainMixerNode.nextAvailableInputBus, format: hardwareFormat)
            }
            engine.connect(generator.node, to: routes.map { AVAudioConnectionPoint(node: $0, bus: 0) }, fromBus: 0, format: format)
            timecodeGenerator = generator; timecodeRoutes = routes
        }
        timecodeTrackID = track.id
        var settings = track.timecode ?? TimecodeSettings()
        let position = transport.playing || transport.paused == true ? transport.position : transport.editPosition ?? transport.position
        let span = TimecodePlaybackSpan(song: song, track: track, position: position, settings: settings, preferredRegion: transport.regionId)
        settings = span?.clip.timecode ?? settings
        let now = ProcessInfo.processInfo.systemUptime
        let delay = span?.delay ?? 0
        let time = span?.time ?? position + settings.offset
        let end = span?.end ?? time
        let active = transport.playing && span != nil && !track.mute && span?.clip.muted != true
        let mode = track.mute || span == nil || span?.clip.muted == true ? "" : settings.mode
        let destination = AudioDeviceSettings.shared.resolvedMIDIDestination(settings.midiDestination)
        let key = "\(span?.clip.id.uuidString ?? "")-\(span?.clip.startTime ?? 0)-\(active)-\(mode)-\(settings.frameRate)-\(destination)-\(settings.regionRelative)-\(settings.offset)-\(end)"
        let changed = timecodeAnchor.map { $0.key != key || (!mode.isEmpty && abs(time - ($0.position + (active ? now + delay - $0.host : 0))) > (active ? 0.08 : 0.000001)) } ?? true
        // Re-anchoring clears the generator's native peak. Consume the audio
        // already rendered before a seek or delayed transport update resets it.
        // Inactive/MTC states discard pending readings immediately instead.
        if let bank = trackPeaks[track.id] {
            let peak = timecodeGenerator?.takePeak() ?? 0
            if active && mode == "ltc" {
                bank.recordPeak(peak, slot: 0); bank.recordPeak(peak, slot: 1)
            } else {
                _ = bank.takePeak(0); _ = bank.takePeak(1)
                meters[track.id]?.reset()
            }
        }
        if changed {
            timecodeGenerator?.configurePosition(time, end: end, hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: delay), rate: settings.frameRate, mode: mode, running: active, destination: destination)
            timecodeAnchor = (key,time,now + delay)
        }
        if timecodePreviewGain?.original != track.volume { timecodePreviewGain = nil }
        timecodePhaseInverted = track.phaseInverted == true
        let manual = timecodePreviewGain?.value ?? track.volume
        timecodeGenerator?.setGain(Float(effectiveLoopGain(track.id, manual: manual)) * (timecodePhaseInverted ? -1 : 1))
        configureRoutes(timecodeRoutes, patches: mode == "ltc" && !masterSolo ? track.outputPatches : [])
    }
    func refreshMetronome() {
        // Apply the user switch directly to the render thread, even without a
        // current transport snapshot. Clock updates cannot reopen this gate.
        metronome?.setEnabled(MetronomeSettings.shared.enabled)
        if metronome != nil { configureRoutes([metronomeRoute], patches: [MetronomeSettings.shared.output]) }
        guard let latestPlayback, let song = latestPlayback.snapshot.project.songs.first(where: { $0.id == latestPlayback.snapshot.transport.songId }) else { return }
        var transport = latestPlayback.snapshot.transport
        if transport.playing {
            transport.position += max(0, ProcessInfo.processInfo.systemUptime - lastUpdate)
            if transport.loop.enabled, let start = transport.loop.start, let end = transport.loop.end, end > start, transport.position >= end {
                transport.position = start + (transport.position - start).truncatingRemainder(dividingBy: end - start)
            }
        }
        updateMetronome(song: song, transport: transport)
    }
    private func detachClickTrack() {
        for click in clickGenerators { engine.detach(click.node) }
        clickGenerators.removeAll(); clickTrackID = nil; clickSections = []
    }
    private func prepareClickTrack(song: Song) throws {
        guard let track = song.tracks.first(where: { $0.kind == .click }) else {
            if clickTrackID != nil { detachClickTrack() }
            return
        }
        let soundChanged = clickSoundPath != track.clickSound?.path || clickSample == nil
        if soundChanged {
            let url = track.clickSound.map { directory!.appendingPathComponent($0.path) }
            if let url, !FileManager.default.fileExists(atPath: url.path) {
                clickSample = Data() // Opening with missing media keeps the custom click silent.
            } else { clickSample = try ClickAudioSample.load(sampleRate: hardwareFormat.sampleRate, url: url) }
            clickSoundPath = track.clickSound?.path
        }
        if clickTrackID != track.id {
            detachClickTrack()
            let bus = trackBus(for: track.id)
            let format = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.sampleRate, channels: 2)!
            for _ in 0..<2 {
                let click = JarasMetronomeGenerator(format: format)
                engine.attach(click.node)
                engine.connect(click.node, to: bus.mix, fromBus: 0, toBus: bus.mix.nextAvailableInputBus, format: format)
                clickGenerators.append(click)
            }
            clickTrackID = track.id
        }
        let sections = ClickTrackProgram.sections(song: song, track: track)
        if soundChanged || clickSections != sections {
            let values = sections.map { ["start": $0.start, "end": $0.end, "origin": $0.origin, "bpm": $0.bpm, "beats": Double($0.beats), "unit": Double($0.unit)] }
            for click in clickGenerators { click.setClickSections(values, sound: clickSample ?? Data()) }
            clickSections = sections
        }
    }
    private func updateClickPosition(_ transport: TransportState, only head: Int? = nil) {
        for (index, click) in clickGenerators.enumerated() where head == nil || head == index {
            let position = index == 0 ? transport.position : transport.subPlay.position
            let host = audioHostTime(position: position, head: index) ?? mach_absolute_time()
            let sample = realtime ? nodeSampleTime(host: host, anchor: click.node.lastRenderTime ?? engine.outputNode.lastRenderTime).map(Double.init) ?? .nan : Double(engine.manualRenderingSampleTime)
            click.configurePosition(position, hostTime: host, running: index == 0 ? transport.playing : transport.subPlay.playing,
                loopStart: index == 0 && transport.loop.enabled ? transport.loop.start ?? 0 : 0,
                loopEnd: index == 0 && transport.loop.enabled ? transport.loop.end ?? 0 : 0, sampleTime: sample)
        }
    }
    private func updateMetronome(song: Song, transport: TransportState) {
        guard let metronome else { return }
        let settings = MetronomeSettings.shared
        if settings.enabled {
            let soundChanged = metronomeSoundRevision != settings.soundRevision
            let meter = [song.meterBeats, song.meterUnit]
            if soundChanged || metronomeTiming.isEmpty || metronomeBPM != song.bpm || metronomeMeter != meter || metronomeMarkers != song.markers {
                do {
                    if soundChanged { metronomeSounds = try settings.sounds(sampleRate: metronome.node.outputFormat(forBus: 0).sampleRate) }
                    metronomeTiming = song.tempoSections(until: max(song.duration, (song.markers?.map(\.position).max() ?? 0) + 1))
                    metronome.setSections(metronomeTiming.map { ["start": $0.start, "bpm": $0.bpm, "beats": $0.beats, "unit": $0.unit] }, soundA: metronomeSounds.0, soundB: metronomeSounds.1, mode: settings.mode)
                    metronomeSoundRevision = settings.soundRevision; metronomeBPM = song.bpm; metronomeMeter = meter; metronomeMarkers = song.markers
                } catch { settings.error = error.localizedDescription }
            }
        }
        func gain(_ db: Double) -> Float { db <= -60 ? 0 : Float(pow(10, min(6, db) / 20)) }
        metronome.setGainA(gain(settings.gainA), gainB: gain(settings.gainB))
        let host = audioHostTime(position: transport.position, head: 0) ?? mach_absolute_time()
        let sample = nodeSampleTime(host: host, anchor: metronome.node.lastRenderTime ?? engine.outputNode.lastRenderTime)
        metronome.configurePosition(transport.position, hostTime: host, running: settings.enabled && transport.playing,
            loopStart: transport.loop.enabled ? transport.loop.start ?? 0 : 0, loopEnd: transport.loop.enabled ? transport.loop.end ?? 0 : 0,
            sampleTime: sample.map(Double.init) ?? .nan)
    }
    func update(_ snapshot: ShowSnapshot, revision: UInt64, sampledAt: Double = ProcessInfo.processInfo.systemUptime) throws {
        guard directory != nil else { return }
        if !outputAllowed {
            latestPlayback = (snapshot, revision)
            stop()
            return
        }
        #if os(macOS)
        if usesSelectedHardware, !engine.isRunning { try requireSelectedOutput() }
        #endif
        // Project loading is permitted without an available audio device.
        // Build its graph only after a valid hardware format is available.
        try configureMaster()
        var tempoResetCommands: [@Sendable () -> Void] = []
        func cancelPendingTempoVoice(_ key: VoiceKey, _ voice: Voice) {
            // Stop only pending sources: interrupting a buffer does not clear
            // the separately queued file continuation. Keep the graph attached.
            voice.player.volume = 0
            JarasVoiceGain.setRenderEnabled(voice.gain, enabled: false)
            let player = voice.player
            tempoResetCommands.append { player.stop() }
            voiceClockAnchors[ObjectIdentifier(player)] = nil
            voices[key] = nil
            idleVoices[voice.track, default: []].append(voice)
        }
        let previousPlayback = latestPlayback
        let previousTransportPositions = lastPosition
        var previousSourcePositions = lastPosition
        if realtime {
            let host = mach_absolute_time()
            for (head, anchor) in headAudioClock {
                let elapsed = host >= anchor.host ? AVAudioTime.seconds(forHostTime: host - anchor.host) : -AVAudioTime.seconds(forHostTime: anchor.host - host)
                previousSourcePositions[head] = anchor.position + elapsed
            }
        }
        latestPlayback = (snapshot, revision)
        // An edit can republish the last transport sample after plugin loading
        // or history work. Compare positions at their sample epochs; receipt
        // time would turn that unchanged position into a false backward seek.
        let now = sampledAt
        let elapsed = now - lastUpdate; lastUpdate = now
        let transport = snapshot.transport
        let running = transport.playing || transport.subPlay.playing
        if transportWasRunning && !running {
            // Clear both players and effect memory, while keeping the device warm.
            stop()
        }
        guard let song = snapshot.project.songs.first(where: { $0.id == transport.songId }) else { stop(); return }
        let changedLoopGains = updateLoopGainContext(song: song, transport: transport, revision: revision)
        let timelineScale = songID == song.id && song.projectTime.timebase == .relative ? (tempo ?? song.bpm) / song.bpm : 1
        let tempoChanged = abs(timelineScale - 1) > 0.0000001
        let previousSong = previousPlayback?.snapshot.project.songs.first { $0.id == song.id }
        let markerTempoChanged = self.revision != revision && songID == song.id && previousSong.map { old in
            let before = Dictionary(uniqueKeysWithValues: (old.markers ?? []).filter(\.isTempo).map { ($0.id, $0) })
            let after = (song.markers ?? []).filter(\.isTempo)
            return before.count != after.count || after.contains { marker in
                guard let prior = before[marker.id] else { return true }
                return prior.tempoBPM != marker.tempoBPM || prior.tempoTimebase != marker.tempoTimebase ||
                    prior.tempoReferenceBPM != marker.tempoReferenceBPM
            }
        } == true
        if tempoChanged || markerTempoChanged { lastTempoEditTime = now }
        if tempoChanged {
            for head in Array(lastPosition.keys) {
                let old = lastPosition[head]!
                if let host = audioHostTime(position: old, head: head) { headAudioClock[head] = (old * timelineScale, host) }
                lastPosition[head] = old * timelineScale
            }
        }
        tempo = song.bpm
        #if os(macOS)
        for chain in [masterEffects] + trackBuses.values.map(\.effects) { chain.externalTransport(position: transport.position, tempo: song.bpm, beats: Int32(song.meterBeats), unit: Int32(song.meterUnit), playing: transport.playing) }
        #endif
        if tempoChanged || markerTempoChanged {
            for (head, position) in previousSourcePositions { advanceContiguousVoices(head: head, position: position) }
        }
        if self.revision != revision || songID != song.id || lastVideoNoAudio != VideoMediaSettings.shared.noAudio {
            lastVideoNoAudio = VideoMediaSettings.shared.noAudio
            if songID != song.id { stop() }
            if song.tracks.contains(where: { tracks[$0.id]?.midiInput != $0.midiInput || tracks[$0.id]?.midiChannel != $0.midiChannel }) { releaseMIDINotes() }
            tracks = Dictionary(uniqueKeysWithValues: song.tracks.filter { $0.kind == .standard || $0.kind == .click || $0.clips.contains(where: \.isProjectionMedia) }.map { ($0.id, $0) })
            // Gate only live input, before track FX/routing. Keep the source and
            // capture tap running so toggling monitoring cannot interrupt a take.
            for (id, monitor) in inputMonitors {
                monitor.gate.outputVolume = tracks[id] == nil || tracks[id]?.inputMonitoring == false ? 0 : 1
            }
            allowsTempoChanges = song.projectTime.timebase == .relative || song.tempoMarkersAffectAudio
            var tempoPrograms = AudioTempoPrograms(song: song)
            let playbackStarts = PlaybackItemStartIndex(song: song)
            let previousFragmentOwners = Dictionary(uniqueKeysWithValues: clipFragments.flatMap { original, fragments in
                fragments.map { ($0, original) }
            })
            clipFragments.removeAll(keepingCapacity: true); fragmentStarts.removeAll(keepingCapacity: true); fragmentPlaybackStarts.removeAll(keepingCapacity: true)
            contiguousNext.removeAll(keepingCapacity: true); contiguousPrevious.removeAll(keepingCapacity: true); contiguousSourceEnd.removeAll(keepingCapacity: true)
            clips = song.tracks.flatMap { track in
                track.clips.filter { clip in
                    guard let path = clip.audioFile?.path, !clip.isImage, track.kind == .standard || clip.isProjectionMedia else { return false }
                    if clip.isProjectionMedia && VideoMediaSettings.shared.noAudio { return false }
                    return !missingAudioPaths.contains(path)
                }.flatMap { clip in
                    let fragments = tempoPrograms.fragments(for: clip)
                    clipFragments[clip.id] = fragments.map(\.id)
                    if let last = fragments.last {
                        let sourceEnd = last.sourceOffset + last.duration * last.audioRate
                        let continuous = zip(fragments, fragments.dropFirst()).allSatisfy { a, b in
                            abs(a.sourceOffset + a.duration*a.audioRate - b.sourceOffset) < 0.000001
                        } && (clip.loopLength == nil || sourceEnd <= (clip.loopStart ?? 0) + clip.loopLength! + 0.000001)
                        if continuous {
                            for fragment in fragments { contiguousSourceEnd[fragment.id] = sourceEnd }
                            for (a, b) in zip(fragments, fragments.dropFirst()) { contiguousNext[a.id] = b.id; contiguousPrevious[b.id] = a.id }
                        }
                    }
                    let playbackStart = playbackStarts.start(for: clip)
                    for fragment in fragments {
                        fragmentStarts[fragment.id] = clip.startTime
                        fragmentPlaybackStarts[fragment.id] = playbackStart
                    }
                    return fragments.map { (track.id, $0) }
                }
            }
            playbackClipIndex = AudioClipPlaybackIndex(clips: clips.map { $0.1 })
            clipIndices = Dictionary(uniqueKeysWithValues: clips.enumerated().map { ($0.element.1.id, $0.offset) })
            let metered = song.tracks.filter { $0.kind == .standard || $0.kind == .timecode || $0.kind == .click || $0.clips.contains(where: \.isProjectionMedia) }
            let activeIDs = Set(metered.map(\.id))
            for id in trackPeaks.keys where !activeIDs.contains(id) {
                if let bus = trackBuses[id] { JarasEqualizer.setOutputMeteringEnabled(bus.controls, enabled: false) }
            }
            trackPeaks = trackPeaks.filter { activeIDs.contains($0.key) }
            for track in metered where trackPeaks[track.id] == nil {
                trackPeaks[track.id] = JarasMeterBank()
                // Monitoring may create a bus before its track becomes metered.
                // Reusing a removed track must also discard its former peaks.
                if let bus = trackBuses[track.id] {
                    _ = JarasEqualizer.takeOutputPeak(bus.controls, channel: 0)
                    _ = JarasEqualizer.takeOutputPeak(bus.controls, channel: 1)
                    JarasEqualizer.setOutputMeteringEnabled(bus.controls, enabled: true)
                }
            }
            // Prepare routing before Play so starting a file only adds its source.
            for track in song.tracks where track.kind == .standard || track.kind == .click || track.clips.contains(where: \.isProjectionMedia) { _ = trackBus(for: track.id) }
            try prepareClickTrack(song: song)
            connectGroups(); connectTracks()
            for id in Array(idleVoices.keys) where tracks[id] == nil {
                for voice in idleVoices.removeValue(forKey: id) ?? [] { detach(voice) }
            }
            self.revision = revision; songID = song.id
            masterFXSettings = snapshot.project.masterFX ?? NativeFXSettings()
            masterPatches = snapshot.project.masterOutputPatches
            masterPan = snapshot.project.masterPan ?? 0
            master = snapshot.project.masterVolume ?? 1; masterMuted = snapshot.project.masterMute ?? false
            masterSolo = snapshot.project.masterSolo ?? false
            masterMono = snapshot.project.masterMono ?? false
            let byID = Dictionary(uniqueKeysWithValues: clips.map { ($0.1.id, $0) })
            // Tempo-marker edits retime only their occupied regions; song.bpm
            // need not change. Match the same source span after that retiming
            // instead of stopping its player because its timeline bounds moved.
            var retainedTempoVoices = Set<VoiceKey>()
            var tempoAppendCommands: [@Sendable () -> Void] = []
            var rebasedHeads = Set<Int>()
            let previousHeadPositions = previousSourcePositions
            var committedTempoSources: [ObjectIdentifier: Double] = [:]
            var audibleTempoPlayers = Set<ObjectIdentifier>()
            if tempoChanged || markerTempoChanged {
                // An edit can arrive after the old fragment ended but before
                // the next ordinary update retired it. Free that identity
                // before the sounding successor claims a merged fragment.
                for key in Array(voices.keys) {
                    if let voice = voices[key], let old = previousHeadPositions[key.head],
                       voice.clip.startTime + voice.clip.duration <= old { remove(key, keepingTailAt: old) }
                }
                for (key, voice) in voices {
                    let identity = ObjectIdentifier(voice.player)
                    // A replacement needs the same preroll as a fresh start.
                    // Keep an imminent queued onset even before the player has
                    // consumed it; stopping/rewarming all stems can otherwise
                    // spend its remaining deadline and create a silent edge.
                    let lead = realtime ? 0.05 + voice.scheduledProcessingDelay : 0
                    committedTempoSources[identity] = sourcePositionAtRenderClock(voice, protectingOnsetFor: lead)
                    if let old = previousHeadPositions[key.head], old >= voice.clip.startTime,
                       old < voice.clip.startTime + voice.clip.duration { audibleTempoPlayers.insert(identity) }
                }
            }
            func hasCommittedOnset(_ voice: Voice) -> Bool {
                committedTempoSources[ObjectIdentifier(voice.player)] != nil
            }
            if tempoChanged || markerTempoChanged {
                // Remove pending identities before remapping sounding voices.
                // When fragments merge, a future source must never claim the
                // merged item's key ahead of the player already being heard.
                for key in Array(voices.keys) {
                    guard let voice = voices[key], let old = previousHeadPositions[key.head],
                          voice.clip.startTime > old, !hasCommittedOnset(voice) else { continue }
                    cancelPendingTempoVoice(key, voice)
                }
            }
            if markerTempoChanged {
                let nextFragmentOwners = Dictionary(uniqueKeysWithValues: clipFragments.flatMap { original, fragments in
                    fragments.map { ($0, original) }
                })
                let fragmentsByOwner = Dictionary(grouping: clips, by: { nextFragmentOwners[$0.1.id] ?? $0.1.id })
                // The audible source owns a merged fragment before a source
                // whose onset has only reached the stretcher's preroll.
                let orderedKeys = voices.keys.sorted { left, right in
                    let a = voices[left]!, b = voices[right]!
                    let aAudible = audibleTempoPlayers.contains(ObjectIdentifier(a.player))
                    let bAudible = audibleTempoPlayers.contains(ObjectIdentifier(b.player))
                    if aAudible != bAudible { return aAudible }
                    return a.clip.startTime < b.clip.startTime
                }
                for key in orderedKeys {
                    guard var voice = voices[key], let owner = previousFragmentOwners[key.clip],
                          let old = previousHeadPositions[key.head], old < voice.clip.startTime + voice.clip.duration else { continue }
                    let identity = ObjectIdentifier(voice.player)
                    let audible = audibleTempoPlayers.contains(identity)
                    let sourcePosition: Double
                    if audible {
                        sourcePosition = voice.clip.sourceOffset + (old - voice.clip.startTime) * voice.clip.audioRate
                    } else if let rendered = committedTempoSources[identity] {
                        let end = voice.clip.sourceOffset + voice.clip.duration * voice.clip.audioRate
                        sourcePosition = min(max(voice.clip.sourceOffset, rendered), end - 0.5 / voice.file.processingFormat.sampleRate)
                    } else { continue }
                    guard let current = fragmentsByOwner[owner]?.first(where: { track, clip in
                        track == voice.track && clip.audioFile?.path == voice.clip.audioFile?.path &&
                        sourcePosition >= clip.sourceOffset && sourcePosition < clip.sourceOffset + clip.duration * clip.audioRate
                    }) else { continue }
                    let nextKey = VoiceKey(clip: current.1.id, head: key.head)
                    if nextKey != key {
                        guard voices[nextKey] == nil else { continue }
                        setVoice(voices.removeValue(forKey: key), for: nextKey)
                    }
                    // Returning markers to the same rate may merge fragments.
                    // Append any newly exposed source frames to the running
                    // queue instead of restarting its decoder and stretcher.
                    if voice.continuousSource || current.1.loopLength == nil {
                        let end = min(voice.file.length, AVAudioFramePosition((contiguousSourceEnd[current.1.id] ?? (current.1.sourceOffset + current.1.duration * current.1.audioRate)) * voice.file.processingFormat.sampleRate))
                        let count = end - voice.scheduledSourceEnd
                        if count > 0 && count <= Int64(UInt32.max) {
                            let player = voice.player, file = voice.file, first = voice.scheduledSourceEnd
                            tempoAppendCommands.append {
                                player.scheduleSegment(file, startingFrame: first,
                                    frameCount: AVAudioFrameCount(count), at: nil, completionHandler: nil)
                            }
                            voice.scheduledSourceEnd = end
                        }
                    }
                    setVoice(voice, for: nextKey)
                    retainedTempoVoices.insert(nextKey)
                    if audible, !tempoChanged, !rebasedHeads.contains(key.head), let old = previousHeadPositions[key.head],
                       old >= voice.clip.startTime, old < voice.clip.startTime + voice.clip.duration {
                        let mapped = current.1.startTime + (sourcePosition - current.1.sourceOffset) / current.1.audioRate
                        if abs(mapped - old) > 0.0000001 {
                            if let host = audioHostTime(position: old, head: key.head) { headAudioClock[key.head] = (mapped, host) }
                            // Keep the UI snapshot's age separate from the
                            // audible head. Initial source preparation/preroll
                            // can put them on opposite sides of a tempo edge.
                            if let previous = previousTransportPositions[key.head] {
                                let source = voice.clip.sourceOffset + (previous - voice.clip.startTime) * voice.clip.audioRate
                                lastPosition[key.head] = current.1.startTime + (source - current.1.sourceOffset) / current.1.audioRate
                            }
                            rebasedHeads.insert(key.head)
                        }
                    }
                }
            }
            for command in tempoAppendCommands { command() }
            for key in Array(voices.keys) {
                guard let voice = voices[key] else { continue }
                guard let current = byID[key.clip], current.0 == voice.track,
                      (retainedTempoVoices.contains(key) ||
                       (abs(current.1.startTime - voice.clip.startTime * timelineScale) < 0.000001 &&
                        abs(current.1.duration - voice.clip.duration * timelineScale) < 0.000001)),
                      (retainedTempoVoices.contains(key) || abs(current.1.sourceOffset - voice.clip.sourceOffset) < 0.000001), current.1.loopStart == voice.clip.loopStart, current.1.loopLength == voice.clip.loopLength,
                      current.1.audioFile?.path == voice.clip.audioFile?.path,
                      (current.1.frozenMIDI == true) == (voice.clip.frozenMIDI == true) else {
                    if (tempoChanged || markerTempoChanged), let previous = previousHeadPositions[key.head],
                       voice.clip.startTime > previous, !hasCommittedOnset(voice) {
                        cancelPendingTempoVoice(key, voice)
                    } else { remove(key) }
                    continue
                }
                // A scheduled future onset has a wall-clock deadline, so only
                // that pending voice needs a new deadline after a tempo edit.
                let position = key.head == 0 ? transport.position : transport.subPlay.position
                if (tempoChanged || markerTempoChanged) && current.1.startTime > position &&
                    !retainedTempoVoices.contains(key) && !hasCommittedOnset(voice) {
                    // This pending source has only rendered silence. Cancel its
                    // old deadline without disconnecting the track converter.
                    // Rebuilding that graph for every future stem stalls the UI.
                    cancelPendingTempoVoice(key, voice)
                    continue
                }
                let requiresStretch = !realtime || allowsTempoChanges || abs(current.1.audioRate - 1) >= 0.000001 || abs(voice.pitch) >= 0.000001
                if voice.usesStretch != requiresStretch { remove(key); continue }
                if current.1.audioRate != voice.clip.audioRate {
                    configureStretch(voice.stretch, clock: voice.rateClock, rate: Float(current.1.audioRate), pitch: voice.pitch)
                }
                var updated = voice
                if current.1.loopLength != nil && (tempoChanged || markerTempoChanged) {
                    // The player already owns these source frames. Its queue
                    // endpoint is not a wall-clock position after a tempo edit.
                    // Remap it before scheduling the next chunk; otherwise a
                    // slowdown enqueues earlier audio again several seconds later.
                    let queuedSource = voice.clip.sourceOffset + (voice.scheduledUntil - voice.clip.startTime) * voice.clip.audioRate
                    updated.scheduledUntil = current.1.startTime + (queuedSource - current.1.sourceOffset) / current.1.audioRate
                }
                updated.clip = current.1
                applyClipFX(current.1.fx ?? emptyFX, to: &updated)
                setVoice(updated, for: key)

            }
            // Pending DSP has only processed silence. Resetting those audio
            // units synchronously can stall the graph; clearing the source
            // queue is sufficient, and warmPlayer establishes a fresh clock.
            for command in tempoResetCommands { command() }
            for key in Array(effectTails.keys) {
                guard var tail = effectTails[key], let current = byID[key.clip], current.0 == tail.voice.track,
                      (current.1.frozenMIDI == true) == (tail.voice.clip.frozenMIDI == true) else {
                    if let tail = effectTails.removeValue(forKey: key) { recycle(tail.voice) }; continue
                }
                tail.voice.clip = current.1; applyClipFX(current.1.fx ?? emptyFX, to: &tail.voice)
                let linear = current.1.gain ?? 1
                JarasVoiceGain.setDecibels(tail.voice.gain, decibels: Double(current.1.muted == true || linear <= 0 ? -96 : Float(min(24, max(-96, 20 * log10(max(0.0000001, linear)))))))
                effectTails[key] = tail
            }
            discardRetiredVoicesForDeletedTracks()
            applyLevels()
        }
        for id in changedLoopGains where id != MultiLoopTrack.masterID { applyTrackGain(id) }
        if changedLoopGains.contains(MultiLoopTrack.masterID) { applyMasterGain() }
        if pitchParts != song.parts || pitchClipRevision != revision {
            pitchParts = song.parts; pitchClipRevision = revision
            clipPitches = Dictionary(uniqueKeysWithValues: clips.map { track, clip in
                (clip.id, Float(((clip.pitchSemitones ?? 0) + (clip.frozenMIDI == true || clip.renderedTiming == true ? 0 : Double(song.pitch(for: track, region: song.pitchRegion(at: fragmentStarts[clip.id] ?? clip.startTime))))) * 100))
            })
        }
        if running {
            cancelVoicePreparation()
            if !transportWasRunning {
                clearTransportFade()
                // Prepared players keep their graph/clock ready, but unused
                // slots must not render an entire silent item-effects chain.
                for pooled in idleVoices.values {
                    for voice in pooled { JarasVoiceGain.setRenderEnabled(voice.gain, enabled: false) }
                }
            }
        }
        transportWasRunning = running
        setGraphRenderEnabled(running || instrumentRenderPending)
        updateTimecode(song: song, transport: transport)
        if (transport.subPlayPromotion ?? 0) != subPlayPromotion {
            subPlayPromotion = transport.subPlayPromotion ?? 0
            // Keep the secondary players and their scheduled PCM alive. Changing
            // ownership must never stop, reschedule or fade the incoming song.
            for key in Array(voices.keys) where key.head == 0 {
                if let voice = voices.removeValue(forKey: key) {
                    voice.player.stop()
                    JarasVoiceGain.setRenderEnabled(voice.gain, enabled: false)
                    // Silence latency buffered by time stretching on the retired
                    // head; the promoted voice and its processing stay untouched.
                    JarasVoiceGain.setDecibels(voice.gain, decibels: Double(-96))
                    // Recycle after Stop, not during the live handoff.
                    retiredVoices.append(voice)
                }
            }
            for key in Array(voices.keys) where key.head == 1 {
                setVoice(voices.removeValue(forKey: key), for: VoiceKey(clip: key.clip, head: 0))
            }
            clearEffectTails(head: 0)
            for key in Array(effectTails.keys) where key.head == 1 {
                effectTails[VoiceKey(clip: key.clip, head: 0)] = effectTails.removeValue(forKey: key)
            }
            for key in Array(midiTakeVoices.keys) where key.head == 1 {
                let promoted = midiTakeVoices.removeValue(forKey: key)
                let main = VoiceKey(clip: key.clip, head: 0)
                if let old = midiTakeVoices.removeValue(forKey: main) {
                    // No graph mutation on a live handoff. Retire the old
                    // head and reuse its already connected chain later.
                    #if os(macOS)
                    old.effects.setMIDISequenceClock(head: 0, position: 0, clock: 0, running: false, loopStart: 0, loopEnd: 0)
                    old.effects.silenceExternal()
                    old.effects.externalTransport(position: 0, tempo: song.bpm, beats: Int32(song.meterBeats), unit: Int32(song.meterUnit), playing: false)
                    #endif
                    old.effects.resetTails(); old.running = false
                    JarasVoiceGain.setRenderEnabled(old.gain, enabled: false)
                    retiredMIDITakeVoices.append(old)
                }
                midiTakeVoices[main] = promoted
            }
            if clickGenerators.count == 2 { clickGenerators.swapAt(0, 1) }
            headAudioClock[0] = headAudioClock[1]; headAudioClock[1] = nil
            lastPosition[0] = lastPosition[1]
            lastPosition[1] = nil
        }
        if tempoChanged || markerTempoChanged {
            // An edit publishes a remapped transport sample, not a fresh clock
            // tick. Preserve that sample's age, including time spent computing
            // the edit, so the following tick cannot look like a forward seek.
            let head = transport.playing ? 0 : 1
            let position = head == 0 ? transport.position : transport.subPlay.position
            if let previous = lastPosition[head] {
                lastUpdate = now - max(0, elapsed - max(0, position - previous))
            }
        }
        let nowHost = mach_absolute_time()
        for (voice, end) in boundaryTails where nowHost >= end { retireSilently(voice) }
        boundaryTails.removeAll { nowHost >= $0.1 }
        // Retired heads are already silent. Reset their converters separately
        // instead of resetting every outgoing stem in the same UI callback.
        if realtime, running, !retiredVoices.isEmpty { recycle(retiredVoices.removeFirst()) }
        var promotedJump = false
        if let jump = preparedJump, let previous = lastPosition[0] {
            let expected = jump.destination + max(0, previous + elapsed - jump.boundary)
            if transport.playing && abs(transport.position - expected) < 0.08 &&
               (transport.sectionJumpSerial ?? 0) != sectionJumpSerial {
                for key in Array(voices.keys) where key.head == 0 {
                    if let voice = voices.removeValue(forKey: key) { boundaryTails.append((voice, jump.host + AVAudioTime.hostTime(forSeconds: 0.08))) }
                }
                clearEffectTails(head: 0)
                for key in Array(voices.keys) where key.head == 2 { setVoice(voices.removeValue(forKey: key), for: VoiceKey(clip: key.clip, head: 0)) }
                headAudioClock[0] = headAudioClock[2]; headAudioClock[2] = nil
                lastPosition[0] = transport.position - elapsed; lastPosition[2] = nil
                preparedJump = nil; promotedJump = true
            }
        }
        if (transport.sectionJumpSerial ?? 0) != sectionJumpSerial {
            sectionJumpSerial = transport.sectionJumpSerial ?? 0
            if !promotedJump {
                cancelPreparedJump()
                headAudioClock[0] = nil; lastPosition[0] = nil
                clearEffectTails(head: 0)
                for key in Array(voices.keys) where key.head == 0 { remove(key) }
            }
        }
        let nextJump = upcomingJump(transport, song: song, setlist: snapshot.project.regionSetlist)
        if let jump = preparedJump, !transport.playing || jump.revision != revision || nextJump == nil ||
            nextJump!.0 != jump.boundary || nextJump!.1 != jump.destination || nextJump!.2 != jump.section || nextJump!.3 != jump.region {
            cancelPreparedJump()
        }
        if realtime, preparedJump == nil, let next = nextJump, next.0 - transport.position <= 2.0,
           let host = audioHostTime(position: next.0, head: 0), host > nowHost + AVAudioTime.hostTime(forSeconds: 0.015) {
            appliedJumpBoundaries.removeAll(keepingCapacity: true)
            preparedJump = PreparedJump(boundary: next.0, destination: next.1, host: host, section: next.2, region: next.3, revision: revision)
            headAudioClock[2] = (next.1, host)
        }
        var heads = [(0, transport.playing, transport.position), (1, transport.subPlay.playing, transport.subPlay.position)]
        if let jump = preparedJump { heads.append((2, true, jump.destination)) }
        for (head, playing, position) in heads {
            if !playing {
                clearEffectTails(head: head)
                for key in Array(voices.keys) where key.head == head { remove(key) }
                lastPosition[head] = nil; headAudioClock[head] = nil
                continue
            }
            // A tempo edit remaps project time explicitly. Time spent applying
            // that edit is not a user seek: restarting here interrupts every
            // stem and synchronously rebuilds the live audio graph.
            if head != 2, !tempoChanged, !markerTempoChanged,
               let previous = lastPosition[head], abs(position - previous - elapsed) > 0.15 {
                headAudioClock[head] = nil
                clearEffectTails(head: head)
                for key in Array(voices.keys) where key.head == head { remove(key) }
            }
            lastPosition[head] = position
            // A loop is continuous playback; queues and section jumps establish
            // a new entry. Match the core before promoting the prepared head.
            let preparingLoop = head == 2 && preparedJump?.section == nil && preparedJump?.region == nil
            let scope = preparingLoop ? song.playbackScope(transport) : song.playbackScope(transport, head: head,
                destination: head == 2 ? preparedJump?.destination : nil)
            // Cancel already scheduled sources as well as rejecting new ones.
            // Fragment onsets can differ from the original item's attachment.
            for key in Array(voices.keys) where key.head == head {
                if let voice = voices[key], !scope.allows(fragmentPlaybackStarts[voice.clip.id]) { remove(key) }
            }
            for key in Array(effectTails.keys) where key.head == head {
                if let tail = effectTails[key], !scope.allows(fragmentPlaybackStarts[tail.voice.clip.id]) {
                    effectTails[key] = nil; recycle(tail.voice)
                }
            }
            let audiblePosition: Double
            if realtime, let anchor = headAudioClock[head] {
                let now = mach_absolute_time()
                let offset = now >= anchor.host ? AVAudioTime.seconds(forHostTime: now - anchor.host) : -AVAudioTime.seconds(forHostTime: anchor.host - now)
                audiblePosition = anchor.position + offset
            } else { audiblePosition = position }
            advanceContiguousVoices(head: head, position: audiblePosition)
            for key in Array(voices.keys) where key.head == head {
                if let voice = voices[key], voice.clip.startTime + voice.clip.duration <= audiblePosition { remove(key, keepingTailAt: audiblePosition) }
            }
            for key in Array(effectTails.keys) where key.head == head {
                if let tail = effectTails[key], audiblePosition >= tail.until {
                    effectTails[key] = nil; recycle(tail.voice)
                }
            }
            for key in Array(voices.keys) where key.head == head {
                if var voice = voices[key] {
                    let cents = clipPitches[voice.clip.id] ?? 0
                    if voice.usesStretch != (!realtime || allowsTempoChanges || abs(voice.clip.audioRate - 1) >= 0.000001 || abs(cents) >= 0.000001) { remove(key); continue }
                    if voice.pitch != cents {
                        configureStretch(voice.stretch, clock: voice.rateClock, rate: Float(voice.clip.audioRate), pitch: cents)
                        voice.pitch = cents; setVoice(voice, for: key)
                    }
                }
            }
            let prepareEnd: Double? = head == 0 && snapshot.project.regionSetlist?.preparesWithoutPlayback == true && transport.queuedRegionId != nil
                ? song.parts.first(where: { $0.id == transport.regionId }).map { part in
                    part.parentRegionID.flatMap { id in song.parts.first(where: { $0.id == id }) }?.endTime ?? part.endTime
                } : nil
            // Preparation/preroll can leave the UI ahead of rendered audio.
            // A not-yet-audible fragment still needs its full onset and its
            // original deadline even when the UI has crossed its start.
            // A future head's host clock extrapolates BEFORE its destination
            // during preroll. Do not schedule that earlier source material:
            // it would sound before the jump and overlap the outgoing head.
            // After the deadline the audible clock advances normally.
            let schedulingPosition = max(audiblePosition, headAudioClock[head]?.position ?? position)
            var scheduled: [(VoiceKey, Voice, AVAudioFramePosition, AVAudioFrameCount, Double)] = []
            let lookahead = 2 + max(0, position - schedulingPosition)
            let candidates = playbackClipIndex.candidates(at: schedulingPosition, lookahead: lookahead)
            let pending = head == 2 ? candidates.filter {
                let clip = clips[$0].1
                return voices[VoiceKey(clip: clip.id, head: head)] == nil && clip.audioFile != nil && scope.allows(fragmentPlaybackStarts[clip.id])
            }.count : 0
            let secondsToJump = preparedJump.map { jump in
                let now = mach_absolute_time()
                return jump.host > now ? AVAudioTime.seconds(forHostTime: jump.host - now) : 0
            } ?? 0
            let preparationBudget = head == 2 ? Self.jumpPreparationBatchSize(pending: pending, seconds: secondsToJump, interval: elapsed) : Int.max
            for index in candidates {
                let (track, clip) = clips[index]
                guard scope.allows(fragmentPlaybackStarts[clip.id]) else { continue }
                if let prepareEnd, clip.startTime >= prepareEnd { continue }
                let key = VoiceKey(clip: clip.id, head: head)
                if var voice = voices[key], clip.loopLength != nil {
                    let deadline = min(clip.startTime + clip.duration, schedulingPosition + 5)
                    if !voice.continuousSource && voice.scheduledUntil < deadline - 1 {
                        voice.scheduledUntil = try scheduleLoop(file: voice.file, player: voice.player, clip: clip, from: voice.scheduledUntil, until: deadline, onset: false)
                        setVoice(voice, for: key)
                    }
                    continue
                }
                guard voices[key] == nil, !hasContinuousPredecessor(clip.id, head: head), let audio = clip.audioFile else { continue }
                if scheduled.count >= preparationBudget { break }
                // While the tempo is being dragged, distant onsets have no
                // stable deadline. Reserve only the imminent audio horizon;
                // ordinary lookahead resumes as soon as editing settles.
                if realtime, now - lastTempoEditTime < 0.12, clip.startTime - schedulingPosition > 0.65 { continue }
                if clip.isProjectionMedia && silentVideoFiles.contains(audio.path) { continue }
                let file: AVAudioFile
                do { file = try audioFile(audio) }
                catch {
                    guard clip.isProjectionMedia, AudioFileRead.isVideoWithoutAudio(error) else { throw error }
                    silentVideoFiles.insert(audio.path)
                    continue
                }
                let offset = clip.sourceOffset + max(0, schedulingPosition - clip.startTime) * clip.audioRate
                let first = AVAudioFramePosition(offset * file.processingFormat.sampleRate)
                let sourceEnd = contiguousSourceEnd[clip.id] ?? (clip.sourceOffset + clip.duration * clip.audioRate)
                let count = min(file.length - first, AVAudioFramePosition(sourceEnd * file.processingFormat.sampleRate) - first)
                guard clip.loopLength != nil || (first >= 0 && count > 0 && count <= Int64(UInt32.max)) else { continue }
                var voice = try takeVoice(track: track, clip: clip, file: file)
                voice.continuousSource = contiguousSourceEnd[clip.id] != nil
                let player = voice.player
                // Recycled processors are reset before warming. Do not reset a
                // running prepared stretcher here: that breaks its input clock.
                voice.pitch = clipPitches[clip.id] ?? 0
                configureStretch(voice.stretch, clock: voice.rateClock, rate: Float(clip.audioRate), pitch: voice.pitch)
                if realtime && !player.isPlaying {
                    if !engine.isRunning { try startEngineIfNeeded() }
                    warmPlayer(voice)
                }
                // Set only this new item's levels before its scheduled start.
                // Reapplying every track/FX after scheduling could consume the
                // start deadline and mute the first samples of later voices.
                let linear = clip.gain ?? 1
                player.volume = clip.muted == true || linear <= 0 ? 0 : 1
                player.pan = Float(clip.pan ?? 0)
                JarasVoiceGain.setDecibels(voice.gain, decibels: Double(clip.muted == true || linear <= 0 ? -96 : Float(min(24, max(-96, 20 * log10(max(0.0000001, linear)))))))
                // Register the reserved bus before preparing another overlapping item.
                setVoice(voice, for: key)
                scheduled.append((key, voice, first, AVAudioFrameCount(max(0, min(Int64(UInt32.max), count))), max(0, clip.startTime - schedulingPosition)))
            }
            if !engine.isRunning { try startEngineIfNeeded() }
            startMeterClock()
            // A suspended TimePitch/Varispeed path can resume with a current
            // sample counter but a host timestamp from its previous rate epoch.
            // stop()/AU reset does not necessarily clear that converter epoch.
            // Never extrapolate this pair into an audible onset: renew only the
            // affected idle path before choosing the shared playback deadline.
            if realtime, mobileOutput == nil, let outputTime = engine.outputNode.lastRenderTime, outputTime.isHostTimeValid {
                for index in scheduled.indices {
                    let (key, old, first, count, delay) = scheduled[index]
                    guard Self.requiresSourceClockRenewal(source: old.player.lastRenderTime, reference: outputTime,
                                                         latency: old.player.outputPresentationLatency) else { continue }
                    setVoice(nil, for: key)
                    detach(old)
                    var fresh = try makeVoice(track: old.track, clip: old.clip, file: old.file)
                    fresh.continuousSource = old.continuousSource
                    fresh.player.volume = old.player.volume
                    fresh.player.pan = old.player.pan
                    let gain = old.clip.gain ?? 1
                    JarasVoiceGain.setDecibels(fresh.gain, decibels: old.clip.muted == true || gain <= 0 ? -96 : min(24, max(-96, 20 * log10(max(0.0000001, gain)))))
                    warmPlayer(fresh)
                    setVoice(fresh, for: key)
                    scheduled[index] = (key, fresh, first, count, delay)
                }
            }
            let referenceLatency = realtime && !scheduled.isEmpty ? (metronome?.node.outputPresentationLatency ?? masterBus.outputPresentationLatency) : 0
            func processingDelay(_ voice: Voice) -> Double {
                guard realtime else { return 0 }
                return max(0, voice.player.outputPresentationLatency - referenceLatency)
            }
            // Finish file reads and latency queries before choosing a common deadline.
            let preparedDelays = scheduled.map { processingDelay($0.1) }
            let commands = try scheduled.map { entry -> (end: Double, command: @Sendable (AVAudioTime?) -> Void) in
                let voice = entry.1, clip = voice.clip
                if let length = clip.loopLength {
                    let sampleRate = voice.file.processingFormat.sampleRate
                    let loopFirst = AVAudioFramePosition((clip.loopStart ?? 0) * sampleRate)
                    let loopEnd = min(voice.file.length, loopFirst + AVAudioFramePosition(length * sampleRate))
                    // REAPER enables looping by default even on ordinary stems.
                    // A contiguous source span needs one decoder queue, exactly
                    // like a non-looped file, not periodic five-second appends.
                    if entry.2 < loopFirst || entry.2 + Int64(entry.3) > loopEnd ||
                        (clip.sourceOffset + clip.duration * clip.audioRate) * sampleRate > Double(loopEnd) + 0.5 {
                        let start = max(clip.startTime, schedulingPosition)
                        return try prepareLoop(file: voice.file, player: voice.player, clip: clip, from: start, until: start + 5, onset: true)
                    }
                }
                return (clip.startTime + clip.duration, try startCommand(file: voice.file, player: voice.player, first: entry.2, count: entry.3))
            }
            if realtime && headAudioClock[head] == nil {
                let preroll = preparedDelays.max() ?? 0
                // Rendering can already be ahead of wall time by an I/O buffer.
                let renderHost = mobileOutput?.renderTime?.hostTime ?? engine.outputNode.lastRenderTime?.hostTime ?? 0
                let base = max(mach_absolute_time(), renderHost)
                headAudioClock[head] = (position, base + AVAudioTime.hostTime(forSeconds: 0.05 + preroll))
            }
            if head == 0 { updateMetronome(song: song, transport: transport) }
            if head < 2 { updateClickPosition(transport, only: head) }
            var startCommands: [@Sendable () -> Void] = []
            for (index, entry) in scheduled.enumerated() {
                let (key, prepared, first, count, delay) = entry
                var voice = prepared
                let clip = voice.clip
                var playbackTime = realtime ? AVAudioTime(hostTime: audioHostTime(position: schedulingPosition + delay - preparedDelays[index], head: head)!) : nil
                if !realtime && delay > 0 {
                    playbackTime = AVAudioTime(sampleTime: AVAudioFramePosition((delay * voice.file.processingFormat.sampleRate * clip.audioRate).rounded()), atRate: voice.file.processingFormat.sampleRate)
                }
                if realtime, let hostTime = playbackTime {
                    let key = ObjectIdentifier(voice.player)
                    if let node = voice.player.lastRenderTime, node.isSampleTimeValid || node.isHostTimeValid,
                       let player = voice.player.playerTime(forNodeTime: node) { voiceClockAnchors[key] = (node, player) }
                    if let anchor = voiceClockAnchors[key], let sample = nodeSampleTime(host: hostTime.hostTime, anchor: anchor.node) {
                        playbackTime = AVAudioTime(sampleTime: anchor.player.sampleTime + sample - anchor.node.sampleTime, atRate: anchor.player.sampleRate)
                    }
                    if mobileOutput != nil, playbackTime?.isHostTimeValid == true {
                        // A just-created player may not have rendered its warm
                        // buffer yet. Its player timeline starts at zero now.
                        let now = mach_absolute_time()
                        let elapsed = hostTime.hostTime >= now ? AVAudioTime.seconds(forHostTime: hostTime.hostTime - now) : -AVAudioTime.seconds(forHostTime: now - hostTime.hostTime)
                        playbackTime = AVAudioTime(sampleTime: AVAudioFramePosition(max(0, elapsed * voice.file.processingFormat.sampleRate).rounded()), atRate: voice.file.processingFormat.sampleRate)
                    }
                }
                voice.scheduledOnset = playbackTime ?? AVAudioTime(sampleTime: 0, atRate: voice.file.processingFormat.sampleRate)
                voice.scheduledProcessingDelay = preparedDelays[index]
                voice.scheduledSourceStart = first
                let fadeLatency = realtime ? max(0, (voice.effects?.equalizer.outputPresentationLatency ?? referenceLatency) - referenceLatency) : 0
                let fadeHost = realtime ? (audioHostTime(position: schedulingPosition + delay - fadeLatency, head: head) ?? 0) : 0
                let fadeSample = realtime ? 0 : (Double(engine.manualRenderingSampleTime) / engine.manualRenderingFormat.sampleRate + delay) * voice.file.processingFormat.sampleRate
                voice.effects?.configureItemFade(clip, position: max(clip.startTime, schedulingPosition), hostTime: fadeHost, sampleTime: fadeSample)
                let command = commands[index].command
                let time = playbackTime
                startCommands.append { command(time) }
                voice.scheduledUntil = commands[index].end
                if voice.continuousSource || clip.loopLength == nil { voice.scheduledSourceEnd = first + AVAudioFramePosition(count) }
                setVoice(voice, for: key)
            }
            // Independent players enqueue together instead of spending an I/O
            // synchronization interval per track before the last one is ready.
            if realtime && startCommands.count > 1 {
                let commands = startCommands
                DispatchQueue.concurrentPerform(iterations: commands.count) { commands[$0]() }
            } else { for command in startCommands { command() } }
            if !realtime { for (_, voice, _, _, _) in scheduled { voice.player.play() } }
            if syncDiagnosticsEnabled && !scheduled.isEmpty {
                let keys = scheduled.map { $0.0 }, generation = headAudioClock[head]?.host
                recordSyncDiagnostics(keys, phase: "scheduled")
                Task { @MainActor [weak self] in
                    for delay: UInt64 in [300_000_000, 1_700_000_000, 3_000_000_000] {
                        try? await Task.sleep(nanoseconds: delay)
                        guard let self, self.headAudioClock[head]?.host == generation else { return }
                        self.recordSyncDiagnostics(keys, phase: "rendering")
                    }
                }
            }
        }
        if let jump = preparedJump {
            // The generator deduplicates this deadline. Retry until its previous
            // edge has rendered, so a short loop cannot overwrite the first beat
            // while the UI is already preparing the following jump.
            for generator in [metronome, clickGenerators.first].compactMap({ $0 }) {
                let sample = nodeSampleTime(host: jump.host, anchor: generator.node.lastRenderTime ?? engine.outputNode.lastRenderTime)
                generator.scheduleJump(jump.destination, hostTime: jump.host, sampleTime: sample.map(Double.init) ?? .nan,
                    loopStart: jump.section == nil && jump.region == nil ? transport.loop.start ?? 0 : 0,
                    loopEnd: jump.section == nil && jump.region == nil ? transport.loop.end ?? 0 : 0)
            }
            // Both heads use the same host clock. Rendering fades the outgoing
            // source at the boundary; no UI timer stops or restarts the audio.
            var reference: Double?
            let pendingBoundaries = voices.filter { key, voice in
                key.head == 0 && voice.effects.map { appliedJumpBoundaries[ObjectIdentifier($0.equalizer)] != jump.host } == true
            }.count
            let boundaryNow = mach_absolute_time()
            let seconds = jump.host > boundaryNow ? AVAudioTime.seconds(forHostTime: jump.host - boundaryNow) : 0
            var boundaryBudget = Self.jumpPreparationBatchSize(pending: pendingBoundaries, seconds: seconds, interval: elapsed)
            for (key, voice) in voices where key.head == 0 {
                guard let effects = voice.effects else { continue }
                let id = ObjectIdentifier(effects.equalizer)
                guard appliedJumpBoundaries[id] != jump.host else { continue }
                guard boundaryBudget > 0 else { break }
                boundaryBudget -= 1
                // Device latency queries synchronize with the audio I/O unit.
                // A prepared boundary is immutable: apply it once per voice,
                // including newly scheduled voices, instead of every UI tick.
                if reference == nil { reference = masterBus.outputPresentationLatency }
                let delay = max(0, effects.equalizer.outputPresentationLatency - reference!)
                let ticks = AVAudioTime.hostTime(forSeconds: delay)
                effects.setPlaybackBoundary(jump.host > ticks ? jump.host - ticks : jump.host)
                appliedJumpBoundaries[id] = jump.host
            }
        }
        applyAutomation(snapshot, song: song, revision: revision)
        applyItemAutomation(transport)
        updateMetronome(song: song, transport: transport)
        updateClickPosition(transport)
        if midiPlanRevision != revision || midiPlanSong != song.id {
            prepareMIDISequences(song: song); midiPlanRevision = revision; midiPlanSong = song.id
        }
        updateMIDISequenceClocks(transport)
        updateMIDITakes(transport, song: song, preserveHeld: tempoChanged || markerTempoChanged)
        if !transport.playing && !transport.subPlay.playing {
            prepareIdleVoices(position: transport.editPosition ?? transport.position, revision: revision)
            for voice in retiredVoices { recycle(voice) }
            retiredVoices.removeAll()
        }
        // Instruments can generate audio while the transport is stopped.
        // Keep polling the existing stereo taps whenever the device is running.
        if !realtime && !transport.playing && !transport.subPlay.playing {
            if engine.isRunning { engine.pause() }
            for meter in meters.values { meter.reset() }
            drainNativeMeterPeaks()
            masterMeter.reset(); _ = peaks.takePeak(masterSlot); _ = peaks.takePeak(masterSlot + 1)
            for bank in trackPeaks.values { _ = bank.takePeak(0); _ = bank.takePeak(1) }
            lastMeterUpdate = 0
        } else {
            if realtime { try prepareDevice() }
            pollMeters(now: now)
        }
    }
    func observeTrackPeak(_ id: UUID, left: Double, right: Double, elapsed: Double) {
        let peak = max(left, right)
        if let meter = meters[id] { meter.update(left: left, right: right, elapsed: elapsed) }
        else if peak >= TrackMeterLevel.PeakHold.displayThreshold { meter(for: id).update(left: left, right: right, elapsed: elapsed) }
        if peak >= TrackMeterLevel.PeakHold.muteThreshold, tracks[id]?.mute == false, let onPeakLimit {
            previewMute(id, muted: true)
            onPeakLimit(id)
        }
    }
    // Call only after the engine stops: no in-flight render may republish a
    // peak from the previous graph after Stop has cleared the visible meters.
    private func discardNativeMeterPeaks() {
        for route in masterRoutes {
            _ = JarasChannelRouter.takeInputPeak(route, channel: 0)
            _ = JarasChannelRouter.takeInputPeak(route, channel: 1)
        }
        for bus in trackBuses.values {
            _ = JarasEqualizer.takeOutputPeak(bus.controls, channel: 0)
            _ = JarasEqualizer.takeOutputPeak(bus.controls, channel: 1)
        }
    }
    private func drainNativeMeterPeaks() {
        if let route = masterRoutes.first {
            peaks.recordPeak(JarasChannelRouter.takeInputPeak(route, channel: 0), slot: masterSlot)
            peaks.recordPeak(JarasChannelRouter.takeInputPeak(route, channel: 1), slot: masterSlot + 1)
        }
        for (id, bank) in trackPeaks {
            guard let bus = trackBuses[id] else { continue }
            bank.recordPeak(JarasEqualizer.takeOutputPeak(bus.controls, channel: 0), slot: 0)
            bank.recordPeak(JarasEqualizer.takeOutputPeak(bus.controls, channel: 1), slot: 1)
        }
    }
    private func resetIdleMeterLevels() {
        // The last REC disarm stops the active meter clock. Do not leave its
        // last input sample painted indefinitely; preserve the held peak number.
        for meter in meters.values { meter.reset() }
        masterMeter.reset()
        for bank in trackPeaks.values { _ = bank.takePeak(0); _ = bank.takePeak(1) }
        _ = peaks.takePeak(masterSlot); _ = peaks.takePeak(masterSlot + 1)
        lastMeterUpdate = 0
    }
    private func pollMeters(now: Double = ProcessInfo.processInfo.systemUptime) {
        #if os(iOS)
        guard !AudioDeviceSettings.shared.localSessionReconfiguring else { return }
        #endif
        guard engine.isRunning, transportWasRunning || instrumentRenderPending || !inputMonitors.isEmpty else {
            resetIdleMeterLevels()
            return
        }
        if now - lastMeterUpdate >= 1.0 / 30.0 - 0.002 {
            let elapsed = lastMeterUpdate == 0 ? 1.0 / 30.0 : now - lastMeterUpdate
            lastMeterUpdate = now
            drainNativeMeterPeaks()
            masterMeter.update(left: Double(peaks.takePeak(masterSlot)), right: Double(peaks.takePeak(masterSlot + 1)), elapsed: elapsed)
            for (id, bank) in trackPeaks {
                var left = Double(bank.takePeak(0)), right = Double(bank.takePeak(1))
                if let monitor = inputMonitors[id], let input = monitor.input {
                    let rawLeft = Double(input.takeInputPeak(UInt(monitor.firstChannel)))
                    let rawRight = monitor.channels > 1 ? Double(input.takeInputPeak(UInt(monitor.firstChannel + 1))) : rawLeft
                    left = max(left, rawLeft); right = max(right, rawRight)
                }
                observeTrackPeak(id, left: left, right: right, elapsed: elapsed)
            }
        }
    }
}

/// Uses the existing stereo readings; no additional polling or audio taps.
#if os(macOS)
import AppKit
import Combine

struct VerticalTrackMeter: NSViewRepresentable {
    let meter: TrackMeterLevel
    let showScale: Bool
    var foreground: Color = .white
    var peakOnly = false
    func makeNSView(context: Context) -> NativeVerticalTrackMeterView {
        let view = NativeVerticalTrackMeterView()
        view.bind(meter, showScale: showScale, foreground: NSColor(foreground), peakOnly: peakOnly)
        return view
    }
    func updateNSView(_ view: NativeVerticalTrackMeterView, context: Context) {
        view.bind(meter, showScale: showScale, foreground: NSColor(foreground), peakOnly: peakOnly)
    }
}

/// One native clip observer services every meter in the same scroll container.
@MainActor private final class NativeMeterClipObserver {
    private static let observers = NSMapTable<NSClipView, NativeMeterClipObserver>.weakToStrongObjects()
    private let views = NSHashTable<NativeVerticalTrackMeterView>.weakObjects()
    private var token: NSObjectProtocol?
    static func forClip(_ clip: NSClipView) -> NativeMeterClipObserver {
        if let observer = observers.object(forKey: clip) { return observer }
        let observer = NativeMeterClipObserver(clip)
        observers.setObject(observer, forKey: clip)
        return observer
    }
    static func refreshExisting(in clip: NSClipView) {
        guard let observer = observers.object(forKey: clip) else { return }
        for view in observer.views.allObjects { view.refreshVisibleDrawing() }
    }
    private init(_ clip: NSClipView) {
        clip.postsBoundsChangedNotifications = true
        token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                for view in self?.views.allObjects ?? [] { view.refreshVisibleDrawing() }
            }
        }
    }
    func add(_ view: NativeVerticalTrackMeterView) { views.add(view) }
    func remove(_ view: NativeVerticalTrackMeterView) { views.remove(view) }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

/// Window visibility changes must wake cached meters even when the amplitude
/// is constant and Combine has no new value to publish (notably the Master).
@MainActor private final class NativeMeterWindowObserver {
    private static let observers = NSMapTable<NSWindow, NativeMeterWindowObserver>.weakToStrongObjects()
    private let views = NSHashTable<NativeVerticalTrackMeterView>.weakObjects()
    private var tokens: [NSObjectProtocol] = []
    private var visibility: NSKeyValueObservation?
    static func forWindow(_ window: NSWindow) -> NativeMeterWindowObserver {
        if let observer = observers.object(forKey: window) { return observer }
        let observer = NativeMeterWindowObserver(window)
        observers.setObject(observer, forKey: window)
        return observer
    }
    private init(_ window: NSWindow) {
        visibility = window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                for view in self?.views.allObjects ?? [] { view.resumeVisibleDrawing() }
            }
        }
        let events: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.didExposeNotification, NSWindow.didChangeScreenNotification,
            NSWindow.didChangeBackingPropertiesNotification, NSWindow.didResizeNotification]
        tokens = events.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    for view in self?.views.allObjects ?? [] {
                        // A window edge moves many fixed-size meter views. Their
                        // cached layer geometry stays valid; layout/backing events
                        // already invalidate it when a meter actually changes.
                        if name == NSWindow.didResizeNotification { view.refreshVisibleDrawing() }
                        else { view.resumeVisibleDrawing() }
                    }
                }
            }
        }
    }
    func add(_ view: NativeVerticalTrackMeterView) { views.add(view) }
    func remove(_ view: NativeVerticalTrackMeterView) { views.remove(view) }
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

@MainActor final class NativeVerticalTrackMeterView: NSView {
    /// Virtualized hosts may add meters after the clip's resize notification.
    /// Flush cached amplitudes only after those channel frames are committed.
    static func refreshVisibleMeters(in clip: NSClipView) {
        NativeMeterClipObserver.refreshExisting(in: clip)
    }
    private weak var meter: TrackMeterLevel?
    private var subscription: AnyCancellable?
    private var peakSubscription: AnyCancellable?
    private var peakDB: Double?
    private var levels = SIMD2<Double>(repeating: 0)
    private var showScale = false
    private var textColor = NSColor.white
    private var peakOnly = false
    private var pendingDrawing = true
    private var pendingPeak = true
    private weak var observedWindow: NSWindow?
    private weak var windowObserver: NativeMeterWindowObserver?
    private weak var installedLayer: CALayer?
    private weak var observedClip: NSClipView?
    private weak var clipObserver: NativeMeterClipObserver?
    private let backgrounds = [CALayer(), CALayer()]
    private let levelClips = [CALayer(), CALayer()]
    private let gradients = [CAGradientLayer(), CAGradientLayer()]
    private let scaleLabels = [CATextLayer(), CATextLayer(), CATextLayer()]
    private let peakLabel = CATextLayer()
    private var geometrySize = CGSize.zero
    private var geometryScale: CGFloat = 0
    private var geometryShowsScale: Bool?
    private static let scaleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.jarasMonospacedSystemFont(ofSize: 7, weight: .semibold),
        .foregroundColor: NSColor.white
    ]
    private static let peakFont = NSFont.jarasMonospacedSystemFont(ofSize: 8, weight: .bold)
    private static let compactScalePeakFont = NSFont.jarasMonospacedSystemFont(ofSize: 6.5, weight: .bold)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let actions = Dictionary(uniqueKeysWithValues:
            ["position", "bounds", "hidden", "string", "contentsScale", "colors", "locations", "opacity", "backgroundColor", "borderColor"].map { ($0, NSNull()) })
        for content in backgrounds + levelClips + gradients + scaleLabels + [peakLabel] { content.actions = actions }
        wantsLayer = true
        layer?.masksToBounds = true
        // All visible content belongs to retained sublayers; the NSView itself
        // has no bitmap to redraw when Core Animation updates its children.
        layerContentsRedrawPolicy = .never
        for channel in 0..<2 {
            let background = backgrounds[channel], clip = levelClips[channel], gradient = gradients[channel]
            background.name = "meter-background-\(channel)"
            background.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            clip.name = "meter-level-\(channel)"; clip.masksToBounds = true
            gradient.name = "meter-gradient-\(channel)"
            gradient.colors = [NSColor(Color.green).cgColor, NSColor(Color.yellow).cgColor, NSColor(Color.red).cgColor]
            gradient.locations = [0, 0.5, 1]
            gradient.startPoint = CGPoint(x: 0.5, y: 0); gradient.endPoint = CGPoint(x: 0.5, y: 1)
            clip.addSublayer(gradient)
            layer?.addSublayer(background); layer?.addSublayer(clip)
        }
        for (index, text) in ["0", "−24", "−∞"].enumerated() {
            let label = scaleLabels[index]
            label.name = "meter-scale-\(index)"
            label.string = NSAttributedString(string: text, attributes: Self.scaleAttributes)
            layer?.addSublayer(label)
        }
        peakLabel.name = "meter-peak"; peakLabel.isHidden = true
        peakLabel.alignmentMode = .center
        layer?.addSublayer(peakLabel)
        installedLayer = layer
        setAccessibilityRole(.image)
        setAccessibilityLabel("Stereo meter, L and R")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var layer: CALayer? {
        didSet {
            // SwiftUI/AppKit can replace a channel host's backing surface while
            // scrolling or revealing the footer, without resizing the meter or
            // publishing another amplitude. Reattach retained bars right here.
            if installedLayer !== layer { refreshVisibleDrawing() }
        }
    }
    override func viewWillDraw() {
        super.viewWillDraw()
        refreshVisibleDrawing()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the reserved number rectangle consumes a click. The bars and
        // scale remain transparent to track selection, scrolling and dragging.
        let local = convert(point, from: superview)
        guard showScale, !isHiddenOrHasHiddenAncestor, bounds.contains(local), peakLabel.frame.contains(local) else { return nil }
        return self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard showScale, peakLabel.frame.contains(convert(event.locationInWindow, from: nil)) else { return }
        meter?.peakHold.clear()
    }
    func bind(_ meter: TrackMeterLevel, showScale: Bool, foreground: NSColor = .white, peakOnly: Bool = false) {
        let color = foreground
        if self.peakOnly != peakOnly || !textColor.isEqual(color) {
            if self.peakOnly != peakOnly { geometryScale = 0 }
            self.peakOnly = peakOnly; textColor = color
            layer?.backgroundColor = nil
            var attributes = Self.scaleAttributes
            attributes[.foregroundColor] = color
            for (index, text) in ["0", "−24", "−∞"].enumerated() {
                scaleLabels[index].string = NSAttributedString(string: text, attributes: attributes)
            }
            pendingPeak = true
        }
        if self.showScale != showScale { self.showScale = showScale; pendingDrawing = true; pendingPeak = true }
        if self.meter !== meter {
            self.meter = meter
            peakSubscription = meter.peakHold.$decibels.sink { [weak self] value in
                guard let self, self.peakDB != value else { return }
                self.peakDB = value; self.pendingPeak = true; self.refreshVisibleDrawing()
            }
            subscription = meter.$levels.sink { [weak self] value in
                guard let self, self.levels != value else { return }
                self.levels = value; self.pendingDrawing = true
                self.refreshVisibleDrawing()
            }
        }
        updateClipObserver(); refreshVisibleDrawing()
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview(); updateClipObserver(); refreshVisibleDrawing()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if observedWindow !== window {
            windowObserver?.remove(self); observedWindow = window
            windowObserver = window.map { NativeMeterWindowObserver.forWindow($0) }
            windowObserver?.add(self)
        }
        updateClipObserver(); resumeVisibleDrawing()
    }
    override func viewDidUnhide() {
        super.viewDidUnhide(); resumeVisibleDrawing()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        geometryScale = 0; pendingDrawing = true; pendingPeak = true; refreshVisibleDrawing()
    }
    override func layout() {
        super.layout()
        if geometrySize != bounds.size { pendingDrawing = true; pendingPeak = true }
        refreshVisibleDrawing()
    }
    private func updateClipObserver() {
        let clip = enclosingScrollView?.contentView
        guard clip !== observedClip else { return }
        clipObserver?.remove(self); observedClip = clip
        clipObserver = clip.map { NativeMeterClipObserver.forClip($0) }
        clipObserver?.add(self)
    }
    private func updateLayerGeometry() {
        let scale = window?.backingScaleFactor ?? 1
        guard geometrySize != bounds.size || geometryScale != scale || geometryShowsScale != showScale else { return }
        geometrySize = bounds.size; geometryScale = scale; geometryShowsScale = showScale
        let width = floor(max(0, min(4.5, (bounds.width - 1) / 2)) * scale) / scale
        // The Track Mixer keeps full-height bars and a transparent peak number
        // after the separate MIDI meter, leaving four points between the bars.
        let sidePeak = peakOnly && showScale
        let peakHeight = min(12, bounds.height)
        let barHeight = bounds.height
        for channel in 0..<2 {
            let rect = CGRect(x: CGFloat(channel) * (width + 1), y: 0, width: width, height: barHeight)
            backgrounds[channel].frame = rect
            levelClips[channel].frame = rect
            // A fixed full-height gradient is clipped from the bottom. Scaling
            // the gradient with amplitude would turn quiet peaks red too.
            gradients[channel].frame = CGRect(origin: .zero, size: rect.size)
            gradients[channel].contentsScale = scale
        }
        for (index, fraction) in [1.0, 0.5, 0.0].enumerated() {
            let label = scaleLabels[index]
            let size = (label.string as! NSAttributedString).size()
            let x = 13 + max(0, (bounds.width - 13 - size.width) / 2)
            label.frame = CGRect(x: x, y: max(0, bounds.height - size.height) * fraction, width: size.width, height: size.height)
            label.contentsScale = scale; label.isHidden = !showScale || peakOnly
        }
        peakLabel.contentsScale = scale
        peakLabel.backgroundColor = nil
        // The meter starts 4pt below the row top. Its native coordinates
        // run upwards: center 33pt below its top aligns with the fader at y=37.
        peakLabel.frame = sidePeak
            ? CGRect(x: 21, y: max(0, bounds.height - 33 - peakHeight / 2), width: max(0, bounds.width - 21), height: peakHeight)
            : CGRect(x: 13, y: max(0, bounds.height - peakHeight) * 0.75,
                     width: max(0, bounds.width - 13), height: peakHeight)
        pendingDrawing = true; pendingPeak = true
    }
    fileprivate func resumeVisibleDrawing() {
        geometryScale = 0; pendingDrawing = true; pendingPeak = true
        refreshVisibleDrawing()
    }
    fileprivate func refreshVisibleDrawing() {
        if let layer, installedLayer !== layer || backgrounds.contains(where: { $0.superlayer !== layer }) || levelClips.contains(where: { $0.superlayer !== layer }) {
            layer.masksToBounds = true
            layer.backgroundColor = nil
            for channel in 0..<2 { layer.addSublayer(backgrounds[channel]); layer.addSublayer(levelClips[channel]) }
            for label in scaleLabels { layer.addSublayer(label) }
            layer.addSublayer(peakLabel); installedLayer = layer
            geometryScale = 0; pendingDrawing = true; pendingPeak = true
        }
        guard pendingDrawing || pendingPeak || geometrySize != bounds.size || geometryShowsScale != showScale,
              let window, window.isVisible, !window.isMiniaturized,
              !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return }
        // Every retained content layer disables its implicit actions once.
        // Let all meters share the window's display commit rather than forcing
        // a global layout/commit separately for every track's amplitude tick.
        updateLayerGeometry()
        if pendingDrawing {
            for channel in 0..<2 {
                let level = levels[channel]
                let fraction = level > 0 && level.isFinite ? min(1, max(0, (20 * log10(level) + 60) / 60)) : 0
                var rect = levelClips[channel].frame
                rect.size.height = backgrounds[channel].bounds.height * fraction
                if levelClips[channel].frame != rect { levelClips[channel].frame = rect }
            }
            pendingDrawing = false
        }
        if pendingPeak {
            peakLabel.isHidden = !showScale
            if showScale {
                let clipping = (peakDB ?? -24) >= 0
                let text = NSAttributedString(string: peakDB.map { String(format: "%+.2f", $0) } ?? "",
                    attributes: [.font: peakOnly ? Self.peakFont : Self.compactScalePeakFont,
                                 .foregroundColor: clipping ? NSColor.red : textColor])
                let left: CGFloat = peakOnly ? 21 : 13
                let available = max(0, bounds.width - left)
                let width = clipping ? min(available, ceil(text.size().width) + 4) : available
                peakLabel.frame.origin.x = left + (available - width) / 2
                peakLabel.frame.size.width = width
                peakLabel.backgroundColor = clipping ? NSColor.black.cgColor : nil
                peakLabel.cornerRadius = 2
                if (peakLabel.string as? NSAttributedString) != text { peakLabel.string = text }
            }
            pendingPeak = false
        }
    }
}

#else
struct VerticalTrackMeter: View {
    @ObservedObject var meter: TrackMeterLevel
    let showScale: Bool
    var foreground: Color = .white
    var peakOnly = false
    private var textColor: Color { foreground }
    var body: some View {
        HStack(spacing: 3) {
            HStack(spacing: 1) {
                channel(meter.levels.x)
                channel(meter.levels.y)
            }.frame(width: 10)
            if showScale {
                VStack(spacing: 0) {
                    scaleSlot("0")
                    Spacer(minLength: 0)
                    TrackPeakReadout(peak: meter.peakHold, compact: true, foreground: textColor)
                    Spacer(minLength: 0)
                    scaleSlot("−24")
                    Spacer(minLength: 0)
                    scaleSlot("−∞")
                }.font(.jarasSystem(size: 7, design: .monospaced)).foregroundStyle(textColor)
            }
        }.frame(maxWidth: peakOnly ? .infinity : nil)
            .accessibilityLabel("Stereo meter, L and R")
    }
    private func scaleSlot(_ text: String) -> some View {
        // Blank typography preserves the existing peak position without drawing
        // or exposing the fixed scale numbers in the Track Mixer style.
        Text(verbatim: peakOnly ? " " : text).font(.jarasSystem(size: 7, weight: .semibold, design: .monospaced))
            .foregroundStyle(textColor).accessibilityHidden(peakOnly)
    }
    private func channel(_ level: Double) -> some View {
        GeometryReader { geometry in
            let fraction = level <= 0 ? 0 : min(1, max(0, (20 * log10(level) + 60) / 60))
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.black.opacity(0.55))
                Rectangle().fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .bottom, endPoint: .top))
                    .mask(alignment: .bottom) { Rectangle().frame(height: geometry.size.height * fraction) }
            }
        }
    }
}
#endif

private final class PreparedSoundFont: @unchecked Sendable {
    let unit: JarasSoundFont
    init(_ unit: JarasSoundFont) { self.unit = unit }
}


struct TrackPeakReadout: View {
    @ObservedObject var peak: TrackMeterLevel.PeakHold
    var compact = false
    var foreground: Color = .white
    var redAtZero = true
    private var fontSize: CGFloat {
        #if os(macOS)
        return 8
        #else
        return compact ? 6.5 : 8
        #endif
    }
    private var readoutWidth: CGFloat {
        #if os(macOS)
        return compact ? 30 : 34
        #else
        return compact ? 27 : 34
        #endif
    }
    var body: some View {
        Button { peak.clear() } label: {
            Text(verbatim: peak.decibels.map { String(format: "%+.2f", $0) } ?? "")
                .font(.jarasSystem(size: fontSize, weight: .bold, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(redAtZero && (peak.decibels ?? -24) >= 0 ? Color.red : foreground)
                .padding(.horizontal, 2).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 2).fill((peak.decibels ?? -24) >= 0 ? Color.black : .clear))
                .frame(width: readoutWidth, height: 12)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Reset peak")
            .accessibilityValue(peak.decibels.map { String(format: "%+.2f dB", $0) } ?? "")
    }
}
