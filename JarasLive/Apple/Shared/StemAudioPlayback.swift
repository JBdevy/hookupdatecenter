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
    private var held: [Int32: Set<UInt8>] = [:]
    var channel: Int = max(1, min(16, UserDefaults.standard.integer(forKey: "jaras.keyboard.channel") == 0 ? 1 : UserDefaults.standard.integer(forKey: "jaras.keyboard.channel"))) {
        didSet { held.removeAll(); notes = []; UserDefaults.standard.set(channel, forKey: "jaras.keyboard.channel") }
    }
    func receive(source: Int32, status: UInt8, number: UInt8, value: UInt8) {
        guard status >= 0x80, status < 0xf0, Int(status & 15) + 1 == channel else { return }
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
        static let muteThreshold = pow(10.0, 20.0 / 20)
        func record(_ amplitude: Double) {
            guard amplitude.isFinite, amplitude >= 1, amplitude > maximum else { return }
            maximum = amplitude
            let db = (20 * log10(amplitude) * 100).rounded() / 100
            if decibels != db { decibels = db }
        }
        func clear() { maximum = 0; decibels = nil }
    }
    let peakHold = PeakHold()
    @Published private(set) var levels = SIMD2<Double>(repeating: 0)
    var level: Double { max(levels.x, levels.y) }
    private var envelope = SIMD2<Double>(repeating: 0)
    func reset() { envelope = .zero; if levels != .zero { levels = .zero } }
    func update(peak: Double, elapsed: Double) { update(left: peak, right: peak, elapsed: elapsed) }
    func update(left: Double, right: Double, elapsed: Double) {
        peakHold.record(max(left, right))
        let peaks = SIMD2(left, right)
        let decay = envelope == .zero ? 0 : pow(10, -24 * max(0, elapsed) / 20)
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
        for clip in track.clips {
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
    static let shared = StemAudioPlayback(engine: AudioDeviceSettings.shared.engine)
    private let engine: AVAudioEngine
    private var licenseAllowed = true
    private var outputAllowed: Bool { !realtime || AudioDeviceSettings.shared.selectedUID != "none" }
    func setLicenseAllowed(_ allowed: Bool) {
        licenseAllowed = allowed
        // Every hardware channel (master, direct outs, click, LTC and instruments)
        // converges here. Track/master controls never write this final gain.
        engine.mainMixerNode.outputVolume = allowed && outputAllowed ? 1 : 0
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
    private let masterBus = AVAudioMixerNode()
    private let masterEffects = NativeEffectsChain()
    private var analysisEffects: [String:Set<String>] = [:]
    var instrumentFile: ((String) -> (URL,Bool)?)?
    private struct InstrumentVoiceKey: Hashable { let track: UUID; let effect: String }
    private var samplers: [InstrumentVoiceKey:JarasSoundFont] = [:]
    private var instrumentRequests: [InstrumentVoiceKey:UUID] = [:]
    private var instrumentNames: [InstrumentVoiceKey:String] = [:]
    private var instrumentGeneration = UUID()
    private var masterFXSettings = NativeFXSettings()
    private let masterChannelMode = JarasEqualizer.makeNode()
    private let masterGain = AVAudioUnitEQ(numberOfBands: 0)
    private let masterRoutes = [JarasChannelRouter.makeNode()]
    private var timecodePhaseInverted = false
    private var masterPatches: [OutputPatch] = [.stereo]
    private var appliedRoutes: [ObjectIdentifier: [OutputPatch]] = [:]
    let masterMeter = TrackMeterLevel()
    private var masterConfigured = false
    private let masterSlot: UInt = 0
    private let peaks = JarasMeterBank()
    private var directory: URL?
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
    private var voices: [VoiceKey: Voice] = [:]
    private var retiredVoices: [Voice] = []
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
        var revision: UInt64
    }
    private var preparedJump: PreparedJump?
    private var boundaryTails: [(Voice, UInt64)] = []
    private func cancelPreparedJump() {
        for key in Array(voices.keys) where key.head == 2 { remove(key) }
        for voice in voices.values { voice.effects?.setPlaybackBoundary() }
        headAudioClock[2] = nil; lastPosition[2] = nil; preparedJump = nil
    }
    private func upcomingJump(_ transport: TransportState, song: Song) -> (Double, Double, UUID?)? {
        guard transport.playing else { return nil }
        var result: (Double, Double, UUID?)?
        if transport.loop.enabled, let a = transport.loop.start, let b = transport.loop.end, b > a, b > transport.position,
           transport.multiLoop?.released != true { result = (b, a, nil) }
        if let id = transport.queuedSectionMarkerId,
           let destination = song.sectionDestinationPosition(id),
           let region = song.parts.filter({ transport.position >= $0.startTime && transport.position < $0.endTime })
            .min(by: { $0.endTime - $0.startTime < $1.endTime - $1.startTime }),
           let trigger = song.markers?.filter({ $0.isSection && $0.position > transport.position + 1e-9 && $0.position <= region.endTime }).min(by: { $0.position < $1.position }),
           result == nil || trigger.position <= result!.0 { result = (trigger.position, destination, id) }
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
        let gain = AVAudioMixerNode()
        let pan = AVAudioMixerNode()
        let polarity = JarasEqualizer.makeNode()
        let hardware = [JarasChannelRouter.makeNode()]
        let effects = NativeEffectsChain()
    }
    private var trackBuses: [UUID: TrackBus] = [:]
    var armedMIDIRecordingTracks: Set<UUID> = []
    private struct InputMonitor {
        let source: AVAudioSourceNode
        let gate: AVAudioMixerNode
    }
    private var inputMonitors: [UUID: InputMonitor] = [:]
    func setInputMonitor(_ track: UUID, source: AVAudioSourceNode?, format: AVAudioFormat? = nil) {
        if inputMonitors[track]?.source === source { return }
        if let old = inputMonitors.removeValue(forKey: track) { engine.detach(old.source); engine.detach(old.gate) }
        if let source, let format {
            let bus = trackBus(for: track)
            let gate = AVAudioMixerNode()
            gate.outputVolume = tracks[track]?.inputMonitoring == false ? 0 : 1
            engine.attach(source); engine.attach(gate)
            engine.connect(source, to: gate, format: format)
            engine.connect(gate, to: bus.mix, fromBus: 0, toBus: availableInputBus(track: track, node: bus.mix), format: format)
            inputMonitors[track] = InputMonitor(source: source, gate: gate)
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
    /// nil means every track is eligible; a solo permits its complete subtree and the ancestors that carry its audio.
    private var soloAudibleTracks: Set<UUID>?
    private var clips: [(UUID, AudioClip)] = []
    private var missingAudioPaths = Set<String>()
    private var unifiedPlaybackStarts: [UUID: Double] = [:]
    private var clipIndices: [UUID: Int] = [:]
    private var clipFragments: [UUID: [UUID]] = [:]
    private var fragmentStarts: [UUID: Double] = [:]
    private var trackPeaks: [UUID: JarasMeterBank] = [:]
    private var meters: [UUID: TrackMeterLevel] = [:]
    private var revision: UInt64?
    private var songID: UUID?
    private var timecodeTrackID: UUID?
    private var timecodePreviewGain: (value: Float, original: Double)?
    private var lastVideoNoAudio: Bool?
    private var silentVideoFiles = Set<String>()
    private var tempo: Double?
    private var allowsTempoChanges = false
    private var voiceClockAnchors: [ObjectIdentifier: (node: AVAudioTime, player: AVAudioTime)] = [:]
    private var timecodeGenerator: JarasTimecodeGenerator?
    private var timecodeRoutes: [AVAudioUnitEffect] = []
    private var timecodeAnchor: (key: String, position: Double, host: Double)?
    private var master = 1.0
    private var masterMono = false
    private var masterMuted = false
    private var masterSolo = false
    private var lastPosition: [Int: Double] = [:]
    private var headAudioClock: [Int: (position: Double, host: UInt64)] = [:]
    private func audioHostTime(position: Double, head: Int) -> UInt64? {
        guard let anchor = headAudioClock[head] else { return nil }
        let delta = position - anchor.position
        let ticks = AVAudioTime.hostTime(forSeconds: abs(delta))
        return delta >= 0 ? anchor.host + ticks : anchor.host - min(anchor.host, ticks)
    }
    private func nodeSampleTime(host: UInt64, anchor: AVAudioTime?) -> AVAudioFramePosition? {
        guard let anchor, anchor.isSampleTimeValid, anchor.isHostTimeValid, anchor.sampleRate > 0 else { return nil }
        let elapsed = host >= anchor.hostTime ? AVAudioTime.seconds(forHostTime: host - anchor.hostTime) : -AVAudioTime.seconds(forHostTime: anchor.hostTime - host)
        return anchor.sampleTime + AVAudioFramePosition((elapsed * anchor.sampleRate / (anchor.audioTimeStamp.mRateScalar > 0 ? anchor.audioTimeStamp.mRateScalar : 1)).rounded())
    }
    private func configureStretch(_ stretch: AVAudioUnitTimePitch, rate: Float, pitch: Float) {
        if stretch.rate != rate { stretch.rate = rate }
        if stretch.pitch != pitch { stretch.pitch = pitch }
        // Keep a prepared tempo processor continuous across live rate edits.
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
        let gain: AVAudioUnitEQ
        let stretch: AVAudioUnitTimePitch
        let usesStretch: Bool
        let track: UUID
        var clip: AudioClip
        var file: AVAudioFile
        var effects: NativeEffectsChain?
        var scheduledUntil = 0.0
        var mixInputBus: AVAudioNodeBus = 0
    }
    init(engine: AVAudioEngine, realtime: Bool = true) {
        self.engine = engine; self.realtime = realtime
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
        let current = hardwareFormat
        return previous.sampleRate != current.sampleRate || previous.channelCount != current.channelCount
    }
    private func scheduleDeviceRecovery() {
        engine.mainMixerNode.outputVolume = licenseAllowed && outputAllowed ? 1 : 0
        guard deviceSessionActive, !engine.isInManualRenderingMode else { return }
        deviceRecovery?.cancel()
        // Core Audio may finish the output format change after CurrentDevice is
        // set. Coalesce that notification and the settings callback into one rebuild.
        deviceRecovery = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000) } catch { return }
            guard let self, self.deviceSessionActive else { return }
            self.deviceRecovery = nil
            guard !self.engine.isRunning || self.outputFormatChanged else { return }
            do { try self.reconfigureDevice() } catch { self.onError(error) }
        }
    }
    /// Reconnect the output and resume both heads from the current transport.
    /// Same-format switches retain plugin instances and their open native editors.
    func reconfigureDevice() throws {
        guard deviceSessionActive || directory != nil else { return }
        let previous = latestPlayback
        let rebuild = outputFormatChanged
        if rebuild { beforeAudioGraphReset() }
        stop(); engine.stop()
        if rebuild { configureGraph(directory: directory) }
        else { engine.mainMixerNode.outputVolume = licenseAllowed && outputAllowed ? 1 : 0
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardwareFormat) }
        defer { if rebuild { afterAudioGraphReset() } }
        if let prepareAfterDeviceChange { try prepareAfterDeviceChange() }
        else if let previous { try update(previous.snapshot, revision: previous.revision) }
        if realtime { try prepareDevice() }
    }
    func open(directory: URL) {
        masterMeter.peakHold.clear()
        for meter in meters.values { meter.peakHold.clear() }
        configureGraph(directory: directory)
    }
    func setMissingAudioPaths(_ paths: Set<String>) { missingAudioPaths = paths }
    private func configureGraph(directory: URL?) {
        stop()
        discardIdleVoices()
        if let generator = timecodeGenerator { engine.detach(generator.node) }
        for route in timecodeRoutes { engine.detach(route) }
        timecodeGenerator = nil; timecodeRoutes = []; timecodeAnchor = nil
        appliedRoutes.removeAll()
        // A project swap rebuilds the graph before it is warmed again by update.
        engine.stop()
        instrumentGeneration = UUID(); instrumentRequests.removeAll(); instrumentNames.removeAll()
        for sampler in samplers.values { engine.detach(sampler.node) }; samplers.removeAll()
        detachClickTrack()
        clickSample = nil; clickSoundPath = nil
        for monitor in inputMonitors.values { engine.detach(monitor.source); engine.detach(monitor.gate) }; inputMonitors.removeAll()
        for bus in trackBuses.values {
            bus.pan.removeTap(onBus: 0)
            engine.detach(bus.silence); engine.detach(bus.mix); engine.detach(bus.processedMix); engine.detach(bus.masterSend); engine.detach(bus.groupSend); engine.detach(bus.internalSend); engine.detach(bus.gain); engine.detach(bus.pan); engine.detach(bus.polarity); for route in bus.hardware { engine.detach(route) }; bus.effects.detach(from: engine)
        }
        trackBuses.removeAll(); groupConnections.removeAll()
        if let metronome { engine.detach(metronome.node); engine.detach(metronomeRoute) }; metronome = nil; metronomeSoundRevision = nil; metronomeTiming = []
        if masterConfigured {
            masterGain.removeTap(onBus: 0)
            for route in masterRoutes { engine.detach(route) }
            masterEffects.detach(from: engine); engine.detach(masterGain); engine.detach(masterChannelMode); engine.detach(masterBus)
            masterConfigured = false
        }
        self.directory = directory; latestPlayback = nil; files.removeAll(); silentVideoFiles.removeAll(); timecodePreviewGain = nil; preparedOnsets.removeAll(); onsetPreparationKey = nil; pitchClipRevision = nil; pitchParts.removeAll(); clipPitches.removeAll(); clipFragments.removeAll(); fragmentStarts.removeAll(); trackPeaks.removeAll(); trackConnections.removeAll(); revision = nil; songID = nil; tempo = nil; subPlayPromotion = 0; sectionJumpSerial = 0
        configureMaster()
        if realtime {
            AudioDeviceSettings.shared.deviceChanged = { [weak self] in
                self?.scheduleDeviceRecovery()
            }
        }
    }
    private func trackBus(for id: UUID) -> TrackBus {
        if let bus = trackBuses[id] { return bus }
        let bus = TrackBus()
        engine.attach(bus.silence); engine.attach(bus.mix); engine.attach(bus.processedMix); engine.attach(bus.masterSend); engine.attach(bus.groupSend)
        engine.attach(bus.gain); engine.attach(bus.pan); engine.attach(bus.polarity); engine.attach(bus.internalSend)
        for route in bus.hardware {
            JarasChannelRouter.setRenderEnabled(route, enabled: !realtime || renderEnabled)
            engine.attach(route); engine.connect(route, to: engine.mainMixerNode, fromBus: 0, toBus: engine.mainMixerNode.nextAvailableInputBus, format: hardwareFormat)
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.sampleRate, channels: 2)!
        engine.connect(bus.masterSend, to: masterBus, fromBus: 0, toBus: masterBus.nextAvailableInputBus, format: format)
        engine.connect(bus.groupSend, to: masterBus, fromBus: 0, toBus: masterBus.nextAvailableInputBus, format: format)
        engine.connect(bus.internalSend, to: masterBus, fromBus: 0, toBus: masterBus.nextAvailableInputBus, format: format)
        bus.internalSend.outputVolume = 0
        let destinations = [AVAudioConnectionPoint(node: bus.masterSend, bus: 0), AVAudioConnectionPoint(node: bus.groupSend, bus: 0), AVAudioConnectionPoint(node: bus.internalSend, bus: 0)] + bus.hardware.map { AVAudioConnectionPoint(node: $0, bus: 0) }
        // The first mixer applies gain/pan; the downstream unity mixer makes
        // that stereo PCM observable by the meter before output routing.
        engine.connect(bus.pan, to: destinations, fromBus: 0, format: format)
        engine.connect(bus.gain, to: bus.pan, format: format)
        engine.connect(bus.polarity, to: bus.gain, format: format)
        engine.connect(bus.processedMix, to: bus.polarity, format: format)
        bus.effects.attach(to: engine, input: bus.mix, format: format, destinations: [AVAudioConnectionPoint(node: bus.processedMix, bus: 0)])
        engine.connect(bus.silence, to: bus.mix, fromBus: 0, toBus: 0, format: format)
        bus.effects.apply(tracks[id]?.fx ?? NativeFXSettings())
        #if os(macOS)
        bus.effects.enableInstrumentMIDI(armedInstrumentTracks.contains(id))
        #endif
        bus.effects.observe(analysisEffects[id.uuidString] ?? [])
        bus.masterSend.outputVolume = 0; bus.groupSend.outputVolume = 0
        if let bank = trackPeaks[id] {
            let slot = 0
            bus.pan.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
                var left: Float = 0, right: Float = 0
                vDSP_maxmgv(data[0], vDSP_Stride(buffer.stride), &left, vDSP_Length(buffer.frameLength))
                vDSP_maxmgv(data[1], vDSP_Stride(buffer.stride), &right, vDSP_Length(buffer.frameLength))
                bank.recordPeak(left, slot: UInt(slot)); bank.recordPeak(right, slot: UInt(slot + 1))
            }
        }
        trackBuses[id] = bus
        return bus
    }
    private var hardwareFormat: AVAudioFormat {
        let output = engine.isInManualRenderingMode ? engine.manualRenderingFormat : engine.outputNode.outputFormat(forBus: 0)
        let count = max(1, output.channelCount)
        if count <= 2 { return AVAudioFormat(standardFormatWithSampleRate: output.sampleRate, channels: count)! }
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | count)!
        return AVAudioFormat(standardFormatWithSampleRate: output.sampleRate, channelLayout: layout)
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
    private func configureMaster() {
        guard !masterConfigured else { return }
        engine.mainMixerNode.outputVolume = licenseAllowed && outputAllowed ? 1 : 0
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardwareFormat)
        if realtime {
            if !deviceSilenceAttached { engine.attach(deviceSilence); deviceSilenceAttached = true }
            engine.connect(deviceSilence, to: engine.mainMixerNode, fromBus: 0, toBus: engine.mainMixerNode.nextAvailableInputBus, format: hardwareFormat)
        }
        engine.attach(masterBus); engine.attach(masterGain); engine.attach(masterChannelMode)
        let format = AVAudioFormat(standardFormatWithSampleRate: (engine.isInManualRenderingMode ? engine.manualRenderingFormat.sampleRate : engine.outputNode.outputFormat(forBus: 0).sampleRate), channels: 2)!
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
        masterEffects.attach(to: engine, input: masterBus, format: format)
        engine.connect(masterEffects.output, to: masterChannelMode, format: format)
        engine.connect(masterChannelMode, to: masterGain, format: format)
        for route in masterRoutes {
            JarasChannelRouter.setRenderEnabled(route, enabled: !realtime || renderEnabled)
            engine.attach(route); engine.connect(route, to: engine.mainMixerNode, fromBus: 0, toBus: engine.mainMixerNode.nextAvailableInputBus, format: hardwareFormat)
        }
        engine.connect(masterGain, to: masterRoutes.map { AVAudioConnectionPoint(node: $0, bus: 0) }, fromBus: 0, format: format)
        for (index, route) in masterRoutes.enumerated() { JarasChannelRouter.configure(route, first: index == 0 ? 1 : -1, count: 2) }
        let bank = peaks, slot = masterSlot
        masterGain.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            guard buffer.frameLength > 0, buffer.format.channelCount > 0 else { return }
            var left: Float = 0, right: Float = 0
            vDSP_maxmgv(channels[0], vDSP_Stride(buffer.stride), &left, vDSP_Length(buffer.frameLength))
            vDSP_maxmgv(channels[min(1, Int(buffer.format.channelCount) - 1)], vDSP_Stride(buffer.stride), &right, vDSP_Length(buffer.frameLength))
            bank.recordPeak(left, slot: slot); bank.recordPeak(right, slot: slot + 1)
        }
        preparedOutputFormat = hardwareFormat
        masterConfigured = true
    }
    var onPeakLimit: ((UUID) -> Void)?
    var onError: (Error) -> Void = { _ in }
    func startDeviceSession() throws {
        guard realtime else { return }
        configureMaster()
        AudioDeviceSettings.shared.deviceChanged = { [weak self] in self?.scheduleDeviceRecovery() }
        try prepareDevice()
    }
    private func prepareDevice() throws {
        _ = engine.mainMixerNode
        if !engine.isRunning { engine.prepare(); try engine.start() }
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
        let active = transportWasRunning || instrumentRenderPending || !inputMonitors.isEmpty
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
        guard deviceSessionActive, !engine.isInManualRenderingMode else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDeviceHealthCheck >= 1 else { return }
        lastDeviceHealthCheck = now
        if !engine.isRunning, deviceRecovery == nil { scheduleDeviceRecovery() }
    }
    func effects(for target: UUID?) -> NativeEffectsChain? {
        guard let target else { return masterEffects }
        if let track = trackBuses[target] { return track.effects }
        for head in 0...2 {
            let key = VoiceKey(clip: target, head: head)
            if let chain = voices[key]?.effects ?? effectTails[key]?.voice.effects { return chain }
        }
        return nil
    }
    func observeEffect(_ target: UUID?, effect: String, active: Bool) {
        let key = target?.uuidString ?? "master"
        if active { analysisEffects[key, default: []].insert(effect) }
        else { analysisEffects[key]?.remove(effect) }
        let observed = analysisEffects[key] ?? []
        if target == nil || target.flatMap({ trackBuses[$0] }) != nil {
            effects(for: target)?.observe(observed)
        } else if let target {
            for head in 0...2 {
                let voiceKey = VoiceKey(clip: target, head: head)
                voices[voiceKey]?.effects?.observe(observed)
                effectTails[voiceKey]?.voice.effects?.observe(observed)
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
        for tail in effectTails.values { tail.voice.gain.globalGain = -96 }
        for key in Array(voices.keys) { remove(key) }
        for voice in retiredVoices { recycle(voice) }
        retiredVoices.removeAll()
        for tail in effectTails.values { recycle(tail.voice) }; effectTails.removeAll()
        for pooled in idleVoices.values {
            for voice in pooled {
                voice.player.stop()
                voice.stretch.auAudioUnit.reset()
                voiceClockAnchors[ObjectIdentifier(voice.player)] = nil
            }
        }
        resetEffectTails()
        instrumentRenderPending = !armedInstrumentTracks.isEmpty
        setGraphRenderEnabled(instrumentRenderPending)
        if !realtime { engine.pause() }
        preparedJump = nil
        for (voice, _) in boundaryTails { recycle(voice) }; boundaryTails.removeAll()
        lastPosition.removeAll(); headAudioClock.removeAll()
        for meter in meters.values { meter.reset() }
        masterMeter.reset(); _ = peaks.takePeak(masterSlot); _ = peaks.takePeak(masterSlot + 1)
        for bank in trackPeaks.values { _ = bank.takePeak(0); _ = bank.takePeak(1) }
        lastMeterUpdate = 0
        if deviceSessionActive { startMeterClock() }
    }
    func prepareForClosing() {
        deviceSessionActive = false
        deviceRecovery?.cancel(); deviceRecovery = nil
        latestPlayback = nil
        meterTimer?.invalidate(); meterTimer = nil
        stop()
        engine.stop()
        if let deviceActivity { ProcessInfo.processInfo.endActivity(deviceActivity); self.deviceActivity = nil }
        if deviceSilenceAttached { engine.detach(deviceSilence); deviceSilenceAttached = false }
        discardIdleVoices()
        #if os(macOS)
        masterEffects.releaseExternal()
        for bus in trackBuses.values { bus.effects.releaseExternal() }
        #endif
        instrumentGeneration = UUID()
        instrumentRequests.removeAll()
        files.removeAll(); silentVideoFiles.removeAll(); timecodePreviewGain = nil; preparedOnsets.removeAll()
        directory = nil
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
        voiceClockAnchors[ObjectIdentifier(voice.player)] = nil
        voice.player.volume = 0
        voice.player.stop()
        voice.stretch.auAudioUnit.reset()
        voice.effects?.resetTails()
        voice.gain.auAudioUnit.reset()
        voice.gain.globalGain = -96
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
        let file = try AVAudioFile(forReading: directory.appendingPathComponent(audio.path))
        files[audio.path] = file
        return file
    }
    private func makeVoice(track: UUID, clip: AudioClip, file: AVAudioFile) throws -> Voice {
        // Each player owns its reader; scheduling overlapping copies must not share a mutable file cursor.
        let playbackFile = try AVAudioFile(forReading: file.url)
        let player = AVAudioPlayerNode(), gain = AVAudioUnitEQ(numberOfBands: 0), stretch = AVAudioUnitTimePitch()
        player.volume = 0
        let pitch = clipPitches[clip.id] ?? 0
        let usesStretch = !realtime || allowsTempoChanges || abs(clip.audioRate - 1) >= 0.000001 || abs(pitch) >= 0.000001
        configureStretch(stretch, rate: Float(clip.audioRate), pitch: pitch); stretch.overlap = 8
        engine.attach(player); engine.attach(gain); engine.attach(stretch)
        let bus = trackBus(for: track).input(for: clip)
        let inputBus = availableInputBus(track: track, node: bus)
        if usesStretch { engine.connect(player, to: stretch, format: file.processingFormat) }
        var voice = Voice(player: player, gain: gain, stretch: stretch, usesStretch: usesStretch, track: track, clip: clip, file: playbackFile)
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
        if let index = idleVoices[track]?.firstIndex(where: { ($0.clip.frozenMIDI == true) == (clip.frozenMIDI == true) && $0.file.processingFormat.isEqual(file.processingFormat) && abs($0.clip.audioRate - clip.audioRate) < 0.000001 && $0.usesStretch == (!realtime || allowsTempoChanges || abs(clip.audioRate - 1) >= 0.000001 || abs(clipPitches[clip.id] ?? 0) >= 0.000001) }) {
            var voice = idleVoices[track]!.remove(at: index)
            if voice.file.url != file.url { voice.file = try AVAudioFile(forReading: file.url) }
            voice.clip = clip
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
                    if self.tracks[track]?.kind == .video {
                        let path = clip.audioFile!.path
                        if self.silentVideoFiles.contains(path) { continue }
                        if (try? self.audioFile(clip.audioFile!)) == nil { self.silentVideoFiles.insert(path); continue }
                    }
                    let file = try self.audioFile(clip.audioFile!)
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
                        self.idleVoices[track, default: []].append(voice)
                    }
                } catch { self.onError(error); return }
            }
            // Finish graph construction before starting any idle player. Start
            // outside the preparation task, on the graph's main control queue.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.realtime, self.preparationKey == key,
                      self.latestPlayback?.snapshot.transport.playing != true,
                      self.latestPlayback?.snapshot.transport.subPlay.playing != true else { return }
                guard self.deviceSessionActive, self.engine.isRunning, self.deviceRecovery == nil else { return }
                let prepared = self.idleVoices.values.flatMap { $0 }.filter { !($0.player.isPlaying) && self.trackBuses[$0.track] != nil }
                for voice in prepared {
                    if self.suspendedVoiceOutputs.remove(ObjectIdentifier(voice.gain)) != nil, let bus = self.trackBuses[voice.track] {
                        self.engine.connect(voice.gain, to: bus.input(for: voice.clip), fromBus: 0, toBus: voice.mixInputBus, format: voice.file.processingFormat)
                    }
                }
                // Prepared players receive I/O cycles even while transport is stopped.
                self.setGraphRenderEnabled(true)
                defer { self.setGraphRenderEnabled(self.transportWasRunning || self.instrumentRenderPending) }
                for voice in prepared { self.warmPlayer(voice) }
            }
        }
    }
    private func warmPlayer(_ voice: Voice) {
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
        engine.detach(voice.player); engine.detach(voice.gain); engine.detach(voice.stretch)
    }
    private func remove(_ key: VoiceKey, keepingTailAt position: Double? = nil) {
        guard let voice = voices.removeValue(forKey: key) else { return }
        if let position, voice.clip.muted != true, voice.clip.fxBypassed != true, (voice.clip.gain ?? 1) > 0,
           let settings = voice.clip.fx, voice.effects != nil {
            var duration = 0.0
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
    private func clearEffectTails(head: Int) {
        for key in Array(effectTails.keys) where key.head == head {
            if let tail = effectTails.removeValue(forKey: key) { recycle(tail.voice) }
        }
    }
    private func applyNormalization(to voice: inout Voice) {
        voice.effects?.updateItemFade(voice.clip)
        voice.effects?.setSourceGain(voice.clip.normalizationGain ?? 1)
        voice.effects?.setSourceChannelMode(voice.clip.channelMode ?? 0)
    }
    func previewItemFade(_ id: UUID, fadeIn: Bool, seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        for fragment in clipFragments[id] ?? [id] {
            if let index = clipIndices[fragment] {
                if fadeIn { clips[index].1.fadeIn = seconds } else { clips[index].1.fadeOut = seconds }
            }
            for head in 0...2 {
                let key = VoiceKey(clip: fragment, head: head)
                if var voice = voices[key] {
                    if fadeIn { voice.clip.fadeIn = seconds } else { voice.clip.fadeOut = seconds }
                    voice.effects?.updateItemFade(voice.clip); voices[key] = voice
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
                if var voice = voices[key] { voice.clip.normalizationGain = gain; applyNormalization(to: &voice); voices[key] = voice }
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
                if var voice = voices[key] { voice.clip.channelMode = mode; applyNormalization(to: &voice); voices[key] = voice }
                if var tail = effectTails[key] { tail.voice.clip.channelMode = mode; applyNormalization(to: &tail.voice); effectTails[key] = tail }
            }
        }
    }
    private func applyClipFX(_ settings: NativeFXSettings, to voice: inout Voice) {
        // Prepare the complete path before scheduling PCM. AVAudioEngine graph
        // rewiring can invalidate an active player's scheduled file segments.
        if voice.effects == nil {
            let chain = NativeEffectsChain(reorderable: false)
            chain.attach(to: engine, input: voice.usesStretch ? voice.stretch : voice.player, format: voice.file.processingFormat,
                         destinations: [AVAudioConnectionPoint(node: voice.gain, bus: 0)])
            chain.observe(analysisEffects[voice.clip.id.uuidString] ?? [])
            voice.effects = chain
        }
        var effective = settings
        if voice.clip.fxBypassed == true {
            effective.eqEnabled = false; effective.compressorEnabled = false; effective.limiterEnabled = false
            effective.delayEnabled = false; effective.reverbEnabled = false; effective.pitchEnabled = false
        }
        voice.effects?.apply(effective)
        applyNormalization(to: &voice)
    }
    func previewClipFXBypass(_ id: UUID, bypassed: Bool) {
        for fragment in clipFragments[id] ?? [id] { previewClipFXBypassFragment(fragment, bypassed: bypassed) }
    }
    private func previewClipFXBypassFragment(_ id: UUID, bypassed: Bool) {
        if let index = clipIndices[id] { clips[index].1.fxBypassed = bypassed }
        for head in 0...2 {
            let key = VoiceKey(clip: id, head: head)
            if var voice = voices[key], voice.clip.fxBypassed != bypassed {
                voice.clip.fxBypassed = bypassed
                applyClipFX(voice.clip.fx ?? emptyFX, to: &voice); voices[key] = voice
            }
            if var tail = effectTails[key], tail.voice.clip.fxBypassed != bypassed {
                tail.voice.clip.fxBypassed = bypassed
                applyClipFX(tail.voice.clip.fx ?? emptyFX, to: &tail.voice); effectTails[key] = tail
            }
        }
    }
    func previewClipFX(_ id: UUID, settings: NativeFXSettings) {
        for fragment in clipFragments[id] ?? [id] { previewClipFXFragment(fragment, settings: settings) }
    }
    private func previewClipFXFragment(_ id: UUID, settings: NativeFXSettings) {
        do { try settings.validateForClip() } catch { return }
        if let index = clipIndices[id] { clips[index].1.fx = settings }
        for head in 0...2 {
            let key = VoiceKey(clip: id, head: head)
            if var voice = voices[key] {
                voice.clip.fx = settings; applyClipFX(settings, to: &voice); voices[key] = voice
            }
            if var tail = effectTails[key] {
                tail.voice.clip.fx = settings; applyClipFX(settings, to: &tail.voice); effectTails[key] = tail
            }
        }
    }
    func previewFX(_ track: UUID?, settings: NativeFXSettings) {
        if let track {
            for (key, sampler) in samplers where key.track == track && !settings.isEnabled(key.effect) { sampler.silence() }
        }
        if let track { tracks[track]?.fx = settings; trackBuses[track]?.effects.apply(settings) }
        else { masterFXSettings = settings; masterEffects.apply(settings) }
        applyLevels()
        #if os(macOS)
        if let error = effects(for: track)?.externalError { onError(error) }
        #endif
    }
    func previewItemGain(_ id: UUID, gain: Double) {
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
                voice.gain.globalGain = voice.clip.muted == true || gain <= 0 ? -96 : decibels
                voices[key] = voice
            }
            if var tail = effectTails[key], tail.voice.clip.gain != gain {
                tail.voice.clip.gain = gain
                tail.voice.gain.globalGain = tail.voice.clip.muted == true || gain <= 0 ? -96 : decibels
                effectTails[key] = tail
            }
        }
    }
    func previewVolume(_ track: UUID?, gain: Double) {
        guard gain.isFinite, gain >= 0 else { return }
        if let track, track == timecodeTrackID {
            let original = latestPlayback?.snapshot.project.songs.flatMap(\.tracks).first { $0.id == track }?.volume ?? 1
            timecodePreviewGain = (Float(gain), original); timecodeGenerator?.setGain(Float(gain) * (timecodePhaseInverted ? -1 : 1)); return
        }
        if let track {
            guard tracks[track] != nil else { return }
            let wasSilent = (tracks[track]?.volume ?? 0) <= 0
            tracks[track]?.volume = gain
            trackBuses[track]?.gain.outputVolume = Float(min(pow(10, 12.0 / 20), max(0, gain)))
            // Fader motion changes one gain parameter. Gate and polarity are
            // independent and only need rewriting when crossing silence.
            if wasSilent != (gain <= 0) { applyTrackGate(track) }
        } else {
            master = gain
            masterGain.globalGain = Float(min(12, max(-96, 20 * log10(max(0.0000001, gain)))))
            masterBus.outputVolume = masterMuted || gain <= 0 ? 0 : 1
        }
    }
    func previewPan(_ id: UUID, pan: Double) {
        tracks[id]?.pan = pan
        trackBuses[id]?.gain.pan = Float(pan)
    }
    func previewMute(_ id: UUID?, muted: Bool) {
        if let id {
            guard let track = tracks[id], track.mute != muted else { return }
            tracks[id]?.mute = muted; applyTrackGate(id)
        } else if masterMuted != muted {
            masterMuted = muted
            masterBus.outputVolume = muted || master <= 0 ? 0 : 1
        }
    }
    func previewPhase(_ id: UUID?, inverted: Bool) {
        if let id {
            if latestPlayback?.snapshot.project.songs.flatMap(\.tracks).contains(where: { $0.id == id && $0.kind == .timecode }) == true {
                timecodePhaseInverted = inverted
                let gain = timecodePreviewGain?.value ?? Float(latestPlayback?.snapshot.project.songs.flatMap(\.tracks).first(where: { $0.id == id })?.volume ?? 1)
                timecodeGenerator?.setGain(inverted ? -gain : gain)
            } else {
                tracks[id]?.phaseInverted = inverted
                if let bus = trackBuses[id] { JarasEqualizer.setPolarity(bus.polarity, inverted: inverted) }
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
                voice.gain.globalGain = muted || gain <= 0 ? -96 : Float(min(24, max(-96, 20 * log10(max(0.0000001, gain)))))
                voices[key] = voice
            }
            if var tail = effectTails[key], tail.voice.clip.muted != muted {
                tail.voice.clip.muted = muted
                let gain = tail.voice.clip.gain ?? 1
                tail.voice.gain.globalGain = muted || gain <= 0 ? -96 : Float(min(24, max(-96, 20 * log10(max(0.0000001, gain)))))
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
    private func applyTrackGate(_ id: UUID) {
        guard let track = tracks[id], let bus = trackBuses[id] else { return }
        bus.pan.outputVolume = track.mute || !(soloAudibleTracks?.contains(id) ?? true) || track.volume <= 0 ? 0 : 1
        JarasEqualizer.setPolarity(bus.polarity, inverted: track.phaseInverted == true)
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
    private func applyLevels() {
        syncInstruments()
        masterEffects.apply(masterFXSettings)
        JarasEqualizer.setPolarity(masterChannelMode, inverted: false)
        JarasEqualizer.setInputChannelMode(masterChannelMode, mode: masterMono ? 3 : 0)
        masterBus.outputVolume = masterMuted || master <= 0 ? 0 : 1
        masterGain.globalGain = Float(min(12, max(-96, 20 * log10(max(0.0000001, master)))))
        applyMasterRoutes(); refreshSoloEligibility()
        for (id, bus) in trackBuses {
            guard let track = tracks[id] else { bus.pan.outputVolume = 0; bus.effects.resetTails(); continue }
            bus.effects.apply(track.fx ?? NativeFXSettings())
            applyTrackGate(id)
            bus.gain.pan = Float(track.pan)
            bus.gain.outputVolume = Float(min(pow(10, 12.0 / 20), max(0, track.volume)))
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
            voice.player.pan = 0
            voice.gain.globalGain = muted || linear <= 0 ? -96 : Float(min(24, max(-96, 20 * log10(max(0.0000001, linear)))))
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
    private func prepareMIDISequences(song: Song) {
        var plans: [UUID: [[String: Double]]] = [:]
        for track in song.tracks where track.kind == .standard {
            let notes = track.clips.flatMap { clip -> [MIDIPlaybackNote] in
                guard clip.midi != nil else { return [] }
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
        for head in 0..<2 {
            for sampler in samplers.values { sampler.sequenceHead(Int32(head), position: 0, clock: 0, running: false, loopStart: 0, loopEnd: 0) }
            #if os(macOS)
            for bus in trackBuses.values { bus.effects.setMIDISequenceClock(head: head, position: 0, clock: 0, running: false, loopStart: 0, loopEnd: 0) }
            #endif
        }
    }
    private var virtualNoteTargets: [UInt8: Set<UUID>] = [:]
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
        guard (21...108).contains(note) else { return }
        releaseKeyboardNote(note)
        let targets = armedInstrumentTracks.union(armedMIDIRecordingTracks).filter { tracks[$0]?.kind == .standard }
        virtualNoteTargets[note] = targets
        for id in targets {
            onLiveKeyboardMIDI?(id, 0x90, note, velocity)
            #if os(macOS)
            trackBuses[id]?.effects.sendExternalMIDI(status: 0x90, number: note, value: velocity)
            #endif
            for (key, sampler) in samplers where key.track == id && tracks[id]?.fx?.isEnabled(key.effect) == true { sampler.sendStatus(0x90, data1: note, data2: velocity) }
            InstrumentKeyboardState.shared.receive(track: id, source: Int32.min, status: 0x90, number: note, value: velocity)
        }
    }
    func releaseKeyboardNote(_ note: UInt8) {
        for id in virtualNoteTargets.removeValue(forKey: note) ?? [] {
            onLiveKeyboardMIDI?(id, 0x80, note, 0)
            #if os(macOS)
            trackBuses[id]?.effects.sendExternalMIDI(status: 0x80, number: note, value: 0)
            #endif
            for (key, sampler) in samplers where key.track == id { sampler.sendStatus(0x80, data1: note, data2: 0) }
            InstrumentKeyboardState.shared.receive(track: id, source: Int32.min, status: 0x80, number: note, value: 0)
        }
    }
    func releaseKeyboardNotes() { for note in Array(virtualNoteTargets.keys) { releaseKeyboardNote(note) } }
    // Only a few milliseconds are read on the scheduling thread. The remaining
    // file continues streaming through AVAudioPlayerNode, without a PCM copy.
    private func scheduleLoop(file: AVAudioFile, player: AVAudioPlayerNode, clip: AudioClip, from start: Double, until end: Double, onset: Bool, at playbackTime: AVAudioTime? = nil) throws -> Double {
        let rate = file.processingFormat.sampleRate
        let loopFirst = max(0, AVAudioFramePosition((clip.loopStart ?? 0) * rate))
        let loopEnd = min(file.length, loopFirst + AVAudioFramePosition((clip.loopLength ?? Double(file.length) / rate) * rate))
        let length = loopEnd - loopFirst
        guard length > 0 else { return start }
        var time = start, fade = onset, segments = 0
        let limit = min(end, clip.startTime + clip.duration)
        while time < limit - 0.5 / rate / clip.audioRate && segments < 1024 {
            let elapsed = AVAudioFramePosition(((time - clip.startTime) * clip.audioRate + clip.sourceOffset) * rate)
            let first = loopFirst + ((elapsed - loopFirst) % length + length) % length
            let count = min(loopEnd - first, max(1, AVAudioFramePosition(((limit - time) * rate * clip.audioRate).rounded())), Int64(UInt32.max))
            if fade { try scheduleStart(file: file, player: player, first: first, count: AVAudioFrameCount(count), at: playbackTime); fade = false }
            else { player.scheduleSegment(file, startingFrame: first, frameCount: AVAudioFrameCount(count), at: nil, completionHandler: nil) }
            time += Double(count) / rate / clip.audioRate; segments += 1
        }
        return time
    }
    private func readOnset(file: AVAudioFile, first: AVAudioFramePosition, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let onset = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw ProjectError.invalid("Could not prepare audio onset")
        }
        file.framePosition = first
        try file.read(into: onset, frameCount: frames)
        guard onset.frameLength > 0, let channels = onset.floatChannelData else {
            throw ProjectError.invalid("Could not read audio onset")
        }
        let length = min(Int(onset.frameLength), Int(ceil(file.processingFormat.sampleRate * 0.003)))
        for channel in 0..<Int(onset.format.channelCount) {
            for sample in 0..<length { channels[channel][sample * onset.stride] *= Float(sample) / Float(max(1, length - 1)) }
        }
        return onset
    }
    private func startCommand(file: AVAudioFile, player: AVAudioPlayerNode, first: AVAudioFramePosition, count: AVAudioFrameCount) throws -> @Sendable (AVAudioTime?) -> Void {
        let frames = min(count, AVAudioFrameCount(ceil(file.processingFormat.sampleRate * 0.1)))
        let key = OnsetKey(path: file.url.path, first: first, frames: frames)
        let onset = try preparedOnsets[key] ?? readOnset(file: file, first: first, frames: frames)
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
    private func scheduleStart(file: AVAudioFile, player: AVAudioPlayerNode, first: AVAudioFramePosition, count: AVAudioFrameCount, at playbackTime: AVAudioTime? = nil) throws {
        try startCommand(file: file, player: player, first: first, count: count)(playbackTime)
    }
    func updateTimecode(_ snapshot: ShowSnapshot) {
        guard directory != nil, let song = snapshot.project.songs.first(where: { $0.id == snapshot.transport.songId }) else { return }
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
        if changed {
            timecodeGenerator?.configurePosition(time, end: end, hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: delay), rate: settings.frameRate, mode: mode, running: active, destination: destination)
            timecodeAnchor = (key,time,now + delay)
        }
        if timecodePreviewGain?.original != track.volume { timecodePreviewGain = nil }
        timecodePhaseInverted = track.phaseInverted == true
        timecodeGenerator?.setGain((timecodePreviewGain?.value ?? Float(track.volume)) * (timecodePhaseInverted ? -1 : 1))
        configureRoutes(timecodeRoutes, patches: mode == "ltc" && !masterSolo ? track.outputPatches : [])
        if let bank = trackPeaks[track.id] {
            let peak = active && mode == "ltc" ? timecodeGenerator?.takePeak() ?? 0 : 0
            bank.recordPeak(peak, slot: 0); bank.recordPeak(peak, slot: 1)
            if mode != "ltc" || !active { meters[track.id]?.reset() }
        }
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
    func update(_ snapshot: ShowSnapshot, revision: UInt64) throws {
        guard directory != nil else { return }
        latestPlayback = (snapshot, revision)
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastUpdate; lastUpdate = now
        let transport = snapshot.transport
        let running = transport.playing || transport.subPlay.playing
        if transportWasRunning && !running {
            // Clear both players and effect memory, while keeping the device warm.
            stop()
        }
        guard let song = snapshot.project.songs.first(where: { $0.id == transport.songId }) else { stop(); return }
        let timelineScale = songID == song.id && song.projectTime.timebase == .relative ? (tempo ?? song.bpm) / song.bpm : 1
        let tempoChanged = abs(timelineScale - 1) > 0.0000001
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
        if self.revision != revision || songID != song.id || lastVideoNoAudio != VideoMediaSettings.shared.noAudio {
            lastVideoNoAudio = VideoMediaSettings.shared.noAudio
            if songID != song.id { stop() }
            if song.tracks.contains(where: { tracks[$0.id]?.midiInput != $0.midiInput || tracks[$0.id]?.midiChannel != $0.midiChannel }) { releaseMIDINotes() }
            tracks = Dictionary(uniqueKeysWithValues: song.tracks.filter { $0.kind == .standard || $0.kind == .video || $0.kind == .click }.map { ($0.id, $0) })
            // Gate only live input, before track FX/routing. Keep the source and
            // capture tap running so toggling monitoring cannot interrupt a take.
            for (id, monitor) in inputMonitors {
                monitor.gate.outputVolume = tracks[id] == nil || tracks[id]?.inputMonitoring == false ? 0 : 1
            }
            allowsTempoChanges = song.projectTime.timebase == .relative || song.tempoMarkersAffectAudio
            let tempoSections = song.tempoSections(until: song.duration)
            clipFragments.removeAll(keepingCapacity: true); fragmentStarts.removeAll(keepingCapacity: true)
            clips = song.tracks.filter { $0.kind == .standard || ($0.kind == .video && !VideoMediaSettings.shared.noAudio) }.flatMap { track in
                track.clips.filter { clip in
                    guard let path = clip.audioFile?.path else { return false }
                    return !missingAudioPaths.contains(path)
                }.flatMap { clip in
                    let fragments = song.tempoAudioSegments(clip, sections: tempoSections)
                    clipFragments[clip.id] = fragments.map(\.id)
                    for fragment in fragments { fragmentStarts[fragment.id] = clip.startTime }
                    return fragments.map { (track.id, $0) }
                }
            }
            unifiedPlaybackStarts = Dictionary(uniqueKeysWithValues: song.parts.filter { $0.parentRegionID != nil }.map { ($0.id, $0.startTime) })
            clipIndices = Dictionary(uniqueKeysWithValues: clips.enumerated().map { ($0.element.1.id, $0.offset) })
            let metered = song.tracks.filter { $0.kind == .standard || $0.kind == .timecode || $0.kind == .video || $0.kind == .click }
            let activeIDs = Set(metered.map(\.id))
            trackPeaks = trackPeaks.filter { activeIDs.contains($0.key) }
            for track in metered where trackPeaks[track.id] == nil { trackPeaks[track.id] = JarasMeterBank() }
            // Prepare routing before Play so starting a file only adds its source.
            for track in song.tracks where track.kind == .standard || track.kind == .video || track.kind == .click { _ = trackBus(for: track.id) }
            try prepareClickTrack(song: song)
            connectGroups(); connectTracks()
            for id in Array(idleVoices.keys) where tracks[id] == nil {
                for voice in idleVoices.removeValue(forKey: id) ?? [] { detach(voice) }
            }
            self.revision = revision; songID = song.id
            masterFXSettings = snapshot.project.masterFX ?? NativeFXSettings()
            masterPatches = snapshot.project.masterOutputPatches
            master = snapshot.project.masterVolume ?? 1; masterMuted = snapshot.project.masterMute ?? false
            masterSolo = snapshot.project.masterSolo ?? false
            masterMono = snapshot.project.masterMono ?? false
            let byID = Dictionary(uniqueKeysWithValues: clips.map { ($0.1.id, $0) })
            for key in Array(voices.keys) {
                guard let current = byID[key.clip], let voice = voices[key], current.0 == voice.track,
                      abs(current.1.startTime - voice.clip.startTime * timelineScale) < 0.000001,
                      abs(current.1.duration - voice.clip.duration * timelineScale) < 0.000001,
                      current.1.sourceOffset == voice.clip.sourceOffset, current.1.loopStart == voice.clip.loopStart, current.1.loopLength == voice.clip.loopLength,
                      current.1.audioFile?.path == voice.clip.audioFile?.path,
                      (current.1.frozenMIDI == true) == (voice.clip.frozenMIDI == true) else { remove(key); continue }
                // A scheduled future onset has a wall-clock deadline, so only
                // that pending voice needs a new deadline after a tempo edit.
                let position = key.head == 0 ? transport.position : transport.subPlay.position
                if tempoChanged && current.1.startTime > position { remove(key); continue }
                let requiresStretch = !realtime || allowsTempoChanges || abs(current.1.audioRate - 1) >= 0.000001 || abs(voice.stretch.pitch) >= 0.000001
                if voice.usesStretch != requiresStretch { remove(key); continue }
                if current.1.audioRate != voice.clip.audioRate {
                    configureStretch(voice.stretch, rate: Float(current.1.audioRate), pitch: voice.stretch.pitch)
                }
                var updated = voice
                updated.clip = current.1
                applyClipFX(current.1.fx ?? emptyFX, to: &updated)
                voices[key] = updated

            }
            for key in Array(effectTails.keys) {
                guard var tail = effectTails[key], let current = byID[key.clip], current.0 == tail.voice.track,
                      (current.1.frozenMIDI == true) == (tail.voice.clip.frozenMIDI == true) else {
                    if let tail = effectTails.removeValue(forKey: key) { recycle(tail.voice) }; continue
                }
                tail.voice.clip = current.1; applyClipFX(current.1.fx ?? emptyFX, to: &tail.voice)
                let linear = current.1.gain ?? 1
                tail.voice.gain.globalGain = current.1.muted == true || linear <= 0 ? -96 : Float(min(24, max(-96, 20 * log10(max(0.0000001, linear)))))
                effectTails[key] = tail
            }
            applyLevels()
        }
        if pitchParts != song.parts || pitchClipRevision != revision {
            pitchParts = song.parts; pitchClipRevision = revision
            clipPitches = Dictionary(uniqueKeysWithValues: clips.map { track, clip in
                (clip.id, Float(((clip.pitchSemitones ?? 0) + (clip.frozenMIDI == true || clip.renderedTiming == true ? 0 : Double(song.pitch(for: track, region: song.pitchRegion(at: fragmentStarts[clip.id] ?? clip.startTime))))) * 100))
            })
        }
        if running { cancelVoicePreparation() }
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
                    // Silence latency buffered by time stretching on the retired
                    // head; the promoted voice and its processing stay untouched.
                    voice.gain.globalGain = -96
                    // Recycle after Stop, not during the live handoff.
                    retiredVoices.append(voice)
                }
            }
            for key in Array(voices.keys) where key.head == 1 {
                voices[VoiceKey(clip: key.clip, head: 0)] = voices.removeValue(forKey: key)
            }
            clearEffectTails(head: 0)
            for key in Array(effectTails.keys) where key.head == 1 {
                effectTails[VoiceKey(clip: key.clip, head: 0)] = effectTails.removeValue(forKey: key)
            }
            if clickGenerators.count == 2 { clickGenerators.swapAt(0, 1) }
            headAudioClock[0] = headAudioClock[1]; headAudioClock[1] = nil
            lastPosition[0] = lastPosition[1]
            lastPosition[1] = nil
        }
        let nowHost = mach_absolute_time()
        for (voice, end) in boundaryTails where nowHost >= end { recycle(voice) }
        boundaryTails.removeAll { nowHost >= $0.1 }
        var promotedJump = false
        if let jump = preparedJump, let previous = lastPosition[0] {
            let expected = jump.destination + max(0, previous + elapsed - jump.boundary)
            if transport.playing && abs(transport.position - expected) < 0.08 &&
               (transport.sectionJumpSerial ?? 0) != sectionJumpSerial {
                for key in Array(voices.keys) where key.head == 0 {
                    if let voice = voices.removeValue(forKey: key) { boundaryTails.append((voice, jump.host + AVAudioTime.hostTime(forSeconds: 0.08))) }
                }
                clearEffectTails(head: 0)
                for key in Array(voices.keys) where key.head == 2 { voices[VoiceKey(clip: key.clip, head: 0)] = voices.removeValue(forKey: key) }
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
        let nextJump = upcomingJump(transport, song: song)
        if let jump = preparedJump, !transport.playing || jump.revision != revision || nextJump == nil ||
            nextJump!.0 != jump.boundary || nextJump!.1 != jump.destination || nextJump!.2 != jump.section {
            cancelPreparedJump()
        }
        if realtime, preparedJump == nil, let next = nextJump, next.0 - transport.position <= 1.0,
           let host = audioHostTime(position: next.0, head: 0), host > nowHost + AVAudioTime.hostTime(forSeconds: 0.015) {
            preparedJump = PreparedJump(boundary: next.0, destination: next.1, host: host, section: next.2, revision: revision)
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
            if head != 2, let previous = lastPosition[head], abs(position - previous - elapsed) > 0.15 {
                headAudioClock[head] = nil
                clearEffectTails(head: head)
                for key in Array(voices.keys) where key.head == head { remove(key) }
            }
            lastPosition[head] = position
            let regionID = head == 0 ? transport.regionId : head == 1 ? transport.queuedRegionId : nil
            let ignoredAfter = head == 0 ? transport.ignoreNextAfter : nil
            if let ignoredAfter {
                for key in Array(voices.keys) where key.head == head {
                    if let voice = voices[key], (fragmentStarts[voice.clip.id] ?? voice.clip.startTime) >= ignoredAfter { remove(key) }
                }
                for key in Array(effectTails.keys) where key.head == head {
                    if let tail = effectTails[key], (fragmentStarts[tail.voice.clip.id] ?? tail.voice.clip.startTime) >= ignoredAfter {
                        effectTails[key] = nil; recycle(tail.voice)
                    }
                }
            }
            let minimumStart = regionID.flatMap { unifiedPlaybackStarts[$0] }
            // Skip stems before the selected drawer song on each head. Future
            // songs still flow normally until the unified region's final edge.
            if let minimumStart {
                for key in Array(voices.keys) where key.head == head {
                    if let voice = voices[key], (fragmentStarts[voice.clip.id] ?? voice.clip.startTime) < minimumStart { remove(key) }
                }
                for key in Array(effectTails.keys) where key.head == head {
                    if let tail = effectTails[key], (fragmentStarts[tail.voice.clip.id] ?? tail.voice.clip.startTime) < minimumStart {
                        effectTails[key] = nil; recycle(tail.voice)
                    }
                }
            }
            let audiblePosition: Double
            if realtime, let anchor = headAudioClock[head] {
                let now = mach_absolute_time()
                let offset = now >= anchor.host ? AVAudioTime.seconds(forHostTime: now - anchor.host) : -AVAudioTime.seconds(forHostTime: anchor.host - now)
                audiblePosition = anchor.position + offset
            } else { audiblePosition = position }
            for key in Array(voices.keys) where key.head == head {
                if let voice = voices[key], voice.clip.startTime + voice.clip.duration <= audiblePosition { remove(key, keepingTailAt: audiblePosition) }
            }
            for key in Array(effectTails.keys) where key.head == head {
                if let tail = effectTails[key], audiblePosition >= tail.until {
                    effectTails[key] = nil; recycle(tail.voice)
                }
            }
            for key in Array(voices.keys) where key.head == head {
                if let voice = voices[key] {
                    let cents = clipPitches[voice.clip.id] ?? 0
                    if voice.usesStretch != (!realtime || allowsTempoChanges || abs(voice.clip.audioRate - 1) >= 0.000001 || abs(cents) >= 0.000001) { remove(key); continue }
                    if voice.stretch.pitch != cents { configureStretch(voice.stretch, rate: voice.stretch.rate, pitch: cents) }
                }
            }
            let prepareEnd: Double? = head == 0 && snapshot.project.regionSetlist?.preparesWithoutPlayback == true && transport.queuedRegionId != nil
                ? song.parts.first(where: { $0.id == transport.regionId }).map { part in
                    part.parentRegionID.flatMap { id in song.parts.first(where: { $0.id == id }) }?.endTime ?? part.endTime
                } : nil
            var scheduled: [(VoiceKey, Voice, AVAudioFramePosition, AVAudioFrameCount, Double)] = []
            for (track, clip) in clips where clip.startTime <= position + 2 && clip.startTime + clip.duration > position {
                guard minimumStart == nil || (fragmentStarts[clip.id] ?? clip.startTime) >= minimumStart! else { continue }
                if let prepareEnd, clip.startTime >= prepareEnd { continue }
                if let ignoredAfter, (fragmentStarts[clip.id] ?? clip.startTime) >= ignoredAfter { continue }
                let key = VoiceKey(clip: clip.id, head: head)
                if var voice = voices[key], clip.loopLength != nil {
                    let deadline = min(clip.startTime + clip.duration, position + 5)
                    if voice.scheduledUntil < deadline - 1 {
                        voice.scheduledUntil = try scheduleLoop(file: voice.file, player: voice.player, clip: clip, from: voice.scheduledUntil, until: deadline, onset: false)
                        voices[key] = voice
                    }
                    continue
                }
                guard voices[key] == nil, let audio = clip.audioFile else { continue }
                if tracks[track]?.kind == .video {
                    if silentVideoFiles.contains(audio.path) { continue }
                    if (try? audioFile(audio)) == nil { silentVideoFiles.insert(audio.path); continue }
                }
                let file = try audioFile(audio)
                let offset = clip.sourceOffset + max(0, position - clip.startTime) * clip.audioRate
                let first = AVAudioFramePosition(offset * file.processingFormat.sampleRate)
                let count = min(file.length - first, AVAudioFramePosition((clip.duration - max(0, position - clip.startTime)) * clip.audioRate * file.processingFormat.sampleRate))
                guard clip.loopLength != nil || (first >= 0 && count > 0 && count <= Int64(UInt32.max)) else { continue }
                let voice = try takeVoice(track: track, clip: clip, file: file)
                let player = voice.player
                // Recycled processors are reset before warming. Do not reset a
                // running prepared stretcher here: that breaks its input clock.
                configureStretch(voice.stretch, rate: Float(clip.audioRate), pitch: clipPitches[clip.id] ?? 0)
                if realtime && !player.isPlaying {
                    if !engine.isRunning { engine.prepare(); try engine.start() }
                    warmPlayer(voice)
                }
                // Set only this new item's levels before its scheduled start.
                // Reapplying every track/FX after scheduling could consume the
                // start deadline and mute the first samples of later voices.
                let linear = clip.gain ?? 1
                player.volume = clip.muted == true || linear <= 0 ? 0 : 1
                player.pan = 0
                voice.gain.globalGain = clip.muted == true || linear <= 0 ? -96 : Float(min(24, max(-96, 20 * log10(max(0.0000001, linear)))))
                // Register the reserved bus before preparing another overlapping item.
                voices[key] = voice
                scheduled.append((key, voice, first, AVAudioFrameCount(max(0, min(Int64(UInt32.max), count))), max(0, clip.startTime - position)))
            }
            if !engine.isRunning { engine.prepare(); try engine.start() }
            startMeterClock()
            let referenceLatency = realtime && !scheduled.isEmpty ? (metronome?.node.outputPresentationLatency ?? masterBus.outputPresentationLatency) : 0
            func processingDelay(_ voice: Voice) -> Double {
                guard realtime else { return 0 }
                return max(0, voice.player.outputPresentationLatency - referenceLatency)
            }
            // Finish file reads and latency queries before choosing a common deadline.
            let preparedDelays = scheduled.map { processingDelay($0.1) }
            let commands = try scheduled.map { entry -> (@Sendable (AVAudioTime?) -> Void)? in
                guard entry.1.clip.loopLength == nil else { return nil }
                return try startCommand(file: entry.1.file, player: entry.1.player, first: entry.2, count: entry.3)
            }
            if realtime && headAudioClock[head] == nil {
                let preroll = preparedDelays.max() ?? 0
                // Rendering can already be ahead of wall time by an I/O buffer.
                let renderHost = engine.outputNode.lastRenderTime?.hostTime ?? 0
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
                var playbackTime = realtime ? AVAudioTime(hostTime: audioHostTime(position: position + delay - preparedDelays[index], head: head)!) : nil
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
                }
                let fadeLatency = realtime ? max(0, (voice.effects?.equalizer.outputPresentationLatency ?? referenceLatency) - referenceLatency) : 0
                let fadeHost = realtime ? (audioHostTime(position: position + delay - fadeLatency, head: head) ?? 0) : 0
                let fadeSample = realtime ? 0 : (Double(engine.manualRenderingSampleTime) / engine.manualRenderingFormat.sampleRate + delay) * voice.file.processingFormat.sampleRate
                voice.effects?.configureItemFade(clip, position: max(clip.startTime, position), hostTime: fadeHost, sampleTime: fadeSample)
                if clip.loopLength != nil {
                    voice.scheduledUntil = try scheduleLoop(file: voice.file, player: voice.player, clip: clip, from: max(clip.startTime, position), until: max(clip.startTime, position) + 5, onset: true, at: playbackTime)
                } else {
                    let command = commands[index]!
                    let time = playbackTime
                    startCommands.append { command(time) }
                    voice.scheduledUntil = clip.startTime + clip.duration
                }
                voices[key] = voice
            }
            // Independent players enqueue together instead of spending an I/O
            // synchronization interval per track before the last one is ready.
            if realtime && startCommands.count > 1 {
                let commands = startCommands
                DispatchQueue.concurrentPerform(iterations: commands.count) { commands[$0]() }
            } else { for command in startCommands { command() } }
            if !realtime { for (_, voice, _, _, _) in scheduled { voice.player.play() } }
        }
        if let jump = preparedJump {
            // Both heads use the same host clock. Rendering fades the outgoing
            // source at the boundary; no UI timer stops or restarts the audio.
            let reference = masterBus.outputPresentationLatency
            for (key, voice) in voices where key.head == 0 {
                let delay = max(0, (voice.effects?.equalizer.outputPresentationLatency ?? reference) - reference)
                let ticks = AVAudioTime.hostTime(forSeconds: delay)
                voice.effects?.setPlaybackBoundary(jump.host > ticks ? jump.host - ticks : jump.host)
            }
        }
        updateMetronome(song: song, transport: transport)
        updateClickPosition(transport)
        if midiPlanRevision != revision || midiPlanSong != song.id {
            prepareMIDISequences(song: song); midiPlanRevision = revision; midiPlanSong = song.id
        }
        updateMIDISequenceClocks(transport)
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
        else if peak >= 1 { meter(for: id).update(left: left, right: right, elapsed: elapsed) }
        if peak >= TrackMeterLevel.PeakHold.muteThreshold, tracks[id]?.mute == false, let onPeakLimit {
            previewMute(id, muted: true)
            onPeakLimit(id)
        }
    }
    private func pollMeters(now: Double = ProcessInfo.processInfo.systemUptime) {
        guard engine.isRunning, transportWasRunning || instrumentRenderPending else { return }
        if now - lastMeterUpdate >= 1.0 / 30.0 - 0.002 {
            let elapsed = lastMeterUpdate == 0 ? 1.0 / 30.0 : now - lastMeterUpdate
            lastMeterUpdate = now
            masterMeter.update(left: Double(peaks.takePeak(masterSlot)), right: Double(peaks.takePeak(masterSlot + 1)), elapsed: elapsed)
            for (id, bank) in trackPeaks {
                let left = Double(bank.takePeak(0)), right = Double(bank.takePeak(1))
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
    func makeNSView(context: Context) -> NativeVerticalTrackMeterView {
        let view = NativeVerticalTrackMeterView()
        view.bind(meter, showScale: showScale)
        return view
    }
    func updateNSView(_ view: NativeVerticalTrackMeterView, context: Context) {
        view.bind(meter, showScale: showScale)
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
                    for view in self?.views.allObjects ?? [] { view.resumeVisibleDrawing() }
                }
            }
        }
    }
    func add(_ view: NativeVerticalTrackMeterView) { views.add(view) }
    func remove(_ view: NativeVerticalTrackMeterView) { views.remove(view) }
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

@MainActor final class NativeVerticalTrackMeterView: NSView {
    private weak var meter: TrackMeterLevel?
    private var subscription: AnyCancellable?
    private var peakSubscription: AnyCancellable?
    private var peakDB: Double?
    private var levels = SIMD2<Double>(repeating: 0)
    private var showScale = false
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
        .font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular),
        .foregroundColor: NSColor(red: 0x9a / 255.0, green: 0xa8 / 255.0, blue: 0xb9 / 255.0, alpha: 1)
    ]
    private static let peakAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 7, weight: .bold), .foregroundColor: NSColor.systemRed
    ]
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func bind(_ meter: TrackMeterLevel, showScale: Bool) {
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
        for channel in 0..<2 {
            let rect = CGRect(x: CGFloat(channel) * (width + 1), y: 0, width: width, height: bounds.height)
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
            label.contentsScale = scale; label.isHidden = !showScale
        }
        peakLabel.contentsScale = scale
        pendingDrawing = true; pendingPeak = true
    }
    fileprivate func resumeVisibleDrawing() {
        geometryScale = 0; pendingDrawing = true; pendingPeak = true
        refreshVisibleDrawing()
    }
    fileprivate func refreshVisibleDrawing() {
        if let layer, installedLayer !== layer || backgrounds.contains(where: { $0.superlayer !== layer }) || levelClips.contains(where: { $0.superlayer !== layer }) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.masksToBounds = true
            for channel in 0..<2 { layer.addSublayer(backgrounds[channel]); layer.addSublayer(levelClips[channel]) }
            for label in scaleLabels { layer.addSublayer(label) }
            layer.addSublayer(peakLabel); installedLayer = layer
            geometryScale = 0; pendingDrawing = true; pendingPeak = true
            CATransaction.commit()
        }
        guard pendingDrawing || pendingPeak || geometrySize != bounds.size || geometryShowsScale != showScale,
              let window, window.isVisible, !window.isMiniaturized,
              !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        updateLayerGeometry()
        if pendingDrawing {
            for channel in 0..<2 {
                let level = levels[channel]
                let fraction = level > 0 && level.isFinite ? min(1, max(0, (20 * log10(level) + 60) / 60)) : 0
                var rect = levelClips[channel].frame
                rect.size.height = bounds.height * fraction
                if levelClips[channel].frame != rect { levelClips[channel].frame = rect }
            }
            pendingDrawing = false
        }
        if pendingPeak {
            peakLabel.isHidden = !showScale || peakDB == nil
            if let peakDB, showScale {
                let text = NSAttributedString(string: String(format: "%+.2f", peakDB), attributes: Self.peakAttributes)
                if (peakLabel.string as? NSAttributedString) != text { peakLabel.string = text }
                let size = text.size()
                peakLabel.frame = CGRect(x: 13, y: max(0, bounds.height - size.height) * 0.75, width: size.width, height: size.height)
            }
            pendingPeak = false
        }
    }
}

#else
struct VerticalTrackMeter: View {
    @ObservedObject var meter: TrackMeterLevel
    let showScale: Bool
    var body: some View {
        HStack(spacing: 3) {
            HStack(spacing: 1) {
                channel(meter.levels.x)
                channel(meter.levels.y)
            }.frame(width: 10)
            if showScale {
                VStack(spacing: 0) {
                    Text("0")
                    Spacer(minLength: 0)
                    if let db = meter.peakHold.decibels { Text(String(format: "%+.2f", db)).foregroundStyle(.red) }
                    Spacer(minLength: 0)
                    Text("−24")
                    Spacer(minLength: 0)
                    Text("−∞")
                }.font(.system(size: 7, design: .monospaced)).foregroundStyle(JarasTheme.secondary)
            }
        }.allowsHitTesting(false).accessibilityLabel("Stereo meter, L and R")
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
    var body: some View {
        Group {
            if let db = peak.decibels { Text(verbatim: String(format: "%+.2f", db)).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.red).fixedSize() }
        }.allowsHitTesting(false)
    }
}
