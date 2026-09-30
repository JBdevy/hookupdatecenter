import AVFoundation
import Accelerate
import SwiftUI

@MainActor final class MetronomeSettings: ObservableObject {
    static let shared = MetronomeSettings()
    @Published var enabled = UserDefaults.standard.bool(forKey: "jaras.metronome.enabled") { didSet { persist("enabled", enabled) } }
    @Published var preset = UserDefaults.standard.string(forKey: "jaras.metronome.preset") ?? "Digital" { didSet { soundRevision &+= 1; persist("preset", preset) } }
    @Published var mode = UserDefaults.standard.integer(forKey: "jaras.metronome.mode") { didSet { soundRevision &+= 1; persist("mode", mode) } }
    @Published var gainA = UserDefaults.standard.double(forKey: "jaras.metronome.gainA") { didSet { persist("gainA", gainA) } }
    @Published var gainB = UserDefaults.standard.double(forKey: "jaras.metronome.gainB") { didSet { persist("gainB", gainB) } }
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
            return pcm((0..<length).map { index in
                let t = Double(index) / sampleRate
                let envelope = min(1, t / 0.0008) * pow(max(0, 1 - t / 0.035), 4)
                let fundamental = sin(2 * Double.pi * hz * t)
                let harmonic = preset == "Digital" ? 0 : sin(2 * Double.pi * hz * 1.67 * t) * (preset == "Wood" ? 0.6 : 0.3)
                return Float((fundamental + harmonic) * envelope * 0.2)
            })
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
        static let muteThreshold = pow(10.0, 10.0 / 20)
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
            if clip.startTime <= position + 0.5 && clip.startTime + clip.duration > position && (upcoming == nil || clip.startTime < upcoming!.startTime) { upcoming = clip }
        }
        guard let clip = current ?? upcoming else { return nil }
        self.clip = clip
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
    private var metronome: JarasMetronomeGenerator?
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
    private var masterPatches: [OutputPatch] = [.stereo]
    private var appliedRoutes: [ObjectIdentifier: [OutputPatch]] = [:]
    let masterMeter = TrackMeterLevel()
    private var masterConfigured = false
    private let masterSlot: UInt = 1022
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
    private var subPlayPromotion: UInt64 = 0
    private var transportWasRunning = false
    // Keep the output clock warm without pulling every track and FX while idle.
    // A disarmed instrument may still be sustaining a note, so its graph stays
    // awake until an explicit Stop releases MIDI notes.
    private var renderEnabled = false
    private var instrumentRenderPending = false
    @MainActor private struct TrackBus {
        let mix = AVAudioMixerNode()
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
        let hardware = [JarasChannelRouter.makeNode()]
        let effects = NativeEffectsChain()
    }
    private var trackBuses: [UUID: TrackBus] = [:]
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
    private func setGraphRenderEnabled(_ enabled: Bool) {
        guard realtime, renderEnabled != enabled else { return }
        renderEnabled = enabled
        for route in masterRoutes { JarasChannelRouter.setRenderEnabled(route, enabled: enabled) }
        for bus in trackBuses.values {
            for route in bus.hardware { JarasChannelRouter.setRenderEnabled(route, enabled: enabled) }
        }
        for route in timecodeRoutes { JarasChannelRouter.setRenderEnabled(route, enabled: enabled) }
    }
    private var groupConnections: [UUID: UUID] = [:]
    private var trackConnections: Set<TrackConnection> = []
    private var tracks: [UUID: Track] = [:]
    private var multiLoopTargets: Set<UUID> = []
    /// nil means every track is eligible; a solo permits its immediate group family.
    private var soloAudibleTracks: Set<UUID>?
    private var clips: [(UUID, AudioClip)] = []
    private var missingAudioPaths = Set<String>()
    private var unifiedPlaybackStarts: [UUID: Double] = [:]
    private var clipIndices: [UUID: Int] = [:]
    private var clipFragments: [UUID: [UUID]] = [:]
    private var fragmentStarts: [UUID: Double] = [:]
    private var slots: [UUID: Int] = [:]
    private var meters: [UUID: TrackMeterLevel] = [:]
    private var revision: UInt64?
    private var songID: UUID?
    private var timecodeTrackID: UUID?
    private var timecodePreviewGain: (value: Float, original: Double)?
    private var lastVideoNoAudio: Bool?
    private var silentVideoFiles = Set<String>()
    private var tempo: Double?
    private var timecodeGenerator: JarasTimecodeGenerator?
    private var timecodeRoutes: [AVAudioUnitEffect] = []
    private var timecodeAnchor: (key: String, position: Double, host: Double)?
    private var master = 1.0
    private var masterMono = false
    private var masterMuted = false
    private var masterSolo = false
    private var lastPosition: [Int: Double] = [:]
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
        else { engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardwareFormat) }
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
        for bus in trackBuses.values {
            bus.pan.removeTap(onBus: 0)
            engine.detach(bus.silence); engine.detach(bus.mix); engine.detach(bus.masterSend); engine.detach(bus.groupSend); engine.detach(bus.internalSend); engine.detach(bus.gain); engine.detach(bus.pan); for route in bus.hardware { engine.detach(route) }; bus.effects.detach(from: engine)
        }
        trackBuses.removeAll(); groupConnections.removeAll()
        if let metronome { engine.detach(metronome.node) }; metronome = nil; metronomeSoundRevision = nil; metronomeTiming = []
        if masterConfigured {
            masterGain.removeTap(onBus: 0)
            for route in masterRoutes { engine.detach(route) }
            masterEffects.detach(from: engine); engine.detach(masterGain); engine.detach(masterChannelMode); engine.detach(masterBus)
            masterConfigured = false
        }
        self.directory = directory; latestPlayback = nil; files.removeAll(); silentVideoFiles.removeAll(); timecodePreviewGain = nil; preparedOnsets.removeAll(); onsetPreparationKey = nil; pitchClipRevision = nil; pitchParts.removeAll(); clipPitches.removeAll(); clipFragments.removeAll(); fragmentStarts.removeAll(); slots.removeAll(); trackConnections.removeAll(); revision = nil; songID = nil; tempo = nil; subPlayPromotion = 0
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
        engine.attach(bus.silence); engine.attach(bus.mix); engine.attach(bus.masterSend); engine.attach(bus.groupSend)
        engine.attach(bus.gain); engine.attach(bus.pan); engine.attach(bus.internalSend)
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
        bus.effects.attach(to: engine, input: bus.mix, format: format, destinations: [AVAudioConnectionPoint(node: bus.gain, bus: 0)])
        engine.connect(bus.silence, to: bus.mix, fromBus: 0, toBus: 0, format: format)
        bus.effects.apply(tracks[id]?.fx ?? NativeFXSettings())
        #if os(macOS)
        bus.effects.enableInstrumentMIDI(armedInstrumentTracks.contains(id))
        #endif
        bus.effects.observe(analysisEffects[id.uuidString] ?? [])
        bus.masterSend.outputVolume = 0; bus.groupSend.outputVolume = 0
        if let slot = slots[id] {
            let bank = peaks
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
            engine.connect(generator.node, to: masterBus, fromBus: 0, toBus: masterBus.nextAvailableInputBus, format: format)
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
                deviceActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Jaras Live realtime audio")
            }
            #endif
        }
        startMeterClock()
    }
    private func startMeterClock() {
        guard realtime else { return }
        let active = transportWasRunning || instrumentRenderPending
        guard meterTimer == nil || meterTimerActive != active else { return }
        meterTimer?.invalidate()
        meterTimerActive = active
        let timer = Timer(timeInterval: active ? 1.0 / 30.0 : 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
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
        for head in 0...1 {
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
            for head in 0...1 {
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
        for head in 0...1 {
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
        metronome?.configurePosition(0, hostTime: mach_absolute_time(), running: false, loopStart: 0, loopEnd: 0)
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
        for voice in voices.values { voice.player.volume = 0; voice.player.stop() }
        for tail in effectTails.values { tail.voice.gain.globalGain = -96 }
        for key in Array(voices.keys) { remove(key) }
        for voice in retiredVoices { recycle(voice) }
        retiredVoices.removeAll()
        for tail in effectTails.values { recycle(tail.voice) }; effectTails.removeAll()
        resetEffectTails()
        instrumentRenderPending = !armedInstrumentTracks.isEmpty
        setGraphRenderEnabled(instrumentRenderPending)
        if !realtime { engine.pause() }
        lastPosition.removeAll()
        for meter in meters.values { meter.reset() }
        masterMeter.reset(); _ = peaks.takePeak(masterSlot); _ = peaks.takePeak(masterSlot + 1)
        for slot in slots.values { _ = peaks.takePeak(UInt(slot)); _ = peaks.takePeak(UInt(slot + 1)) }
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
    private func makeVoice(track: UUID, clip: AudioClip, file: AVAudioFile) -> Voice {
        let player = AVAudioPlayerNode(), gain = AVAudioUnitEQ(numberOfBands: 0), stretch = AVAudioUnitTimePitch()
        player.volume = 0
        stretch.rate = Float(clip.audioRate); stretch.pitch = 0; stretch.overlap = 8
        engine.attach(player); engine.attach(gain); engine.attach(stretch)
        let bus = trackBus(for: track).mix
        let occupied = Set(voices.values.filter { $0.track == track }.map(\.mixInputBus) +
                           effectTails.values.filter { $0.voice.track == track }.map { $0.voice.mixInputBus } +
                           (idleVoices[track] ?? []).map(\.mixInputBus) + retiredVoices.filter { $0.track == track }.map(\.mixInputBus))
        var inputBus: AVAudioNodeBus = 1
        while occupied.contains(inputBus) { inputBus += 1 }
        engine.connect(player, to: stretch, format: file.processingFormat)
        var voice = Voice(player: player, gain: gain, stretch: stretch, track: track, clip: clip, file: file)
        voice.mixInputBus = inputBus
        applyClipFX(clip.fx ?? emptyFX, to: &voice)
        engine.connect(gain, to: bus, fromBus: 0, toBus: inputBus, format: file.processingFormat)
        return voice
    }
    private func takeVoice(track: UUID, clip: AudioClip, file: AVAudioFile) -> Voice {
        if let index = idleVoices[track]?.firstIndex(where: { $0.file.processingFormat.isEqual(file.processingFormat) && abs($0.clip.audioRate - clip.audioRate) < 0.000001 }) {
            var voice = idleVoices[track]!.remove(at: index)
            voice.file = file; voice.clip = clip
            if suspendedVoiceOutputs.remove(ObjectIdentifier(voice.gain)) != nil {
                engine.connect(voice.gain, to: trackBus(for: track).mix, fromBus: 0, toBus: voice.mixInputBus, format: file.processingFormat)
            }
            voice.effects?.observe(analysisEffects[clip.id.uuidString] ?? [])
            applyClipFX(clip.fx ?? emptyFX, to: &voice)
            return voice
        }
        return makeVoice(track: track, clip: clip, file: file)
    }
    private func prepareIdleVoices(position: Double, revision: UInt64) {
        let key = "\(songID?.uuidString ?? "")/\(revision)/\(position)"
        guard preparationKey != key else { return }
        cancelVoicePreparation(); preparationKey = key
        if onsetPreparationKey != key { preparedOnsets.removeAll(keepingCapacity: true); onsetPreparationKey = key }
        let upcoming = clips.filter { $0.1.startTime <= position + 0.5 && $0.1.startTime + $0.1.duration > position && $0.1.audioFile != nil }
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
                        let frames = AVAudioFrameCount(min(available, Int64(ceil(rate * 0.003))))
                        let onsetKey = OnsetKey(path: file.url.path, first: first, frames: frames)
                        self.preparedOnsets[onsetKey] = try self.readOnset(file: file, first: first, frames: frames)
                    }
                    if ready < count {
                        let voice = self.makeVoice(track: track, clip: clip, file: file)
                        self.idleVoices[track, default: []].append(voice)
                    }
                } catch { self.onError(error); return }
            }
        }
    }
    private func detach(_ voice: Voice) {
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
        voice.effects?.setSourceGain(voice.clip.normalizationGain ?? 1)
        voice.effects?.setSourceChannelMode(voice.clip.channelMode ?? 0)
    }
    func previewItemNormalization(_ id: UUID, gain: Double) {
        guard gain.isFinite, gain >= 0 else { return }
        for fragment in clipFragments[id] ?? [id] {
            if let index = clipIndices[fragment] { clips[index].1.normalizationGain = gain }
            for head in 0...1 {
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
            for head in 0...1 {
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
            chain.attach(to: engine, input: voice.stretch, format: voice.file.processingFormat,
                         destinations: [AVAudioConnectionPoint(node: voice.gain, bus: 0)])
            chain.observe(analysisEffects[voice.clip.id.uuidString] ?? [])
            voice.effects = chain
        }
        var effective = settings
        if voice.clip.fxBypassed == true {
            effective.eqEnabled = false; effective.compressorEnabled = false
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
        for head in 0...1 {
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
        for head in 0...1 {
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
        // A clip has at most two scheduled voices. Direct lookup keeps each
        // pointer motion independent of the number of other playing tracks.
        for head in 0...1 {
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
            timecodePreviewGain = (Float(gain), original); timecodeGenerator?.setGain(Float(gain)); return
        }
        if let track {
            guard tracks[track] != nil else { return }
            tracks[track]?.volume = gain
            trackBuses[track]?.gain.outputVolume = Float(min(pow(10, 12.0 / 20), max(0, gain)))
            applyTrackGate(track)
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
        for head in 0...1 {
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
        let solo = Set(tracks.values.filter(\.solo).map(\.id))
        guard !solo.isEmpty else { soloAudibleTracks = nil; return }
        var audible = solo
        for track in tracks.values {
            if let parent = track.parentTrackID {
                if solo.contains(track.id) { audible.insert(parent) }
                if solo.contains(parent) { audible.insert(track.id) }
            }
        }
        soloAudibleTracks = audible
    }
    private func applyTrackGate(_ id: UUID) {
        guard let track = tracks[id], let bus = trackBuses[id] else { return }
        bus.pan.outputVolume = track.mute || !(soloAudibleTracks?.contains(id) ?? true) || track.volume <= 0 ? 0 : 1
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
    private var virtualNoteTargets: [UInt8: Set<UUID>] = [:]
    func releaseMIDINotes() {
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
        let targets = armedInstrumentTracks.filter { tracks[$0]?.kind == .standard }
        virtualNoteTargets[note] = targets
        for id in targets {
            #if os(macOS)
            trackBuses[id]?.effects.sendExternalMIDI(status: 0x90, number: note, value: velocity)
            #endif
            for (key, sampler) in samplers where key.track == id && tracks[id]?.fx?.isEnabled(key.effect) == true { sampler.sendStatus(0x90, data1: note, data2: velocity) }
            InstrumentKeyboardState.shared.receive(track: id, source: Int32.min, status: 0x90, number: note, value: velocity)
        }
    }
    func releaseKeyboardNote(_ note: UInt8) {
        for id in virtualNoteTargets.removeValue(forKey: note) ?? [] {
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
    private func scheduleLoop(file: AVAudioFile, player: AVAudioPlayerNode, clip: AudioClip, from start: Double, until end: Double, onset: Bool) throws -> Double {
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
            if fade { try scheduleStart(file: file, player: player, first: first, count: AVAudioFrameCount(count)); fade = false }
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
        let length = Int(onset.frameLength)
        for channel in 0..<Int(onset.format.channelCount) {
            for sample in 0..<length { channels[channel][sample * onset.stride] *= Float(sample) / Float(max(1, length - 1)) }
        }
        return onset
    }
    private func scheduleStart(file: AVAudioFile, player: AVAudioPlayerNode, first: AVAudioFramePosition, count: AVAudioFrameCount) throws {
        let frames = min(count, AVAudioFrameCount(ceil(file.processingFormat.sampleRate * 0.003)))
        let key = OnsetKey(path: file.url.path, first: first, frames: frames)
        let onset = try preparedOnsets[key] ?? readOnset(file: file, first: first, frames: frames)
        player.scheduleBuffer(onset, completionHandler: nil)
        if count > onset.frameLength {
            player.scheduleSegment(file, startingFrame: first + AVAudioFramePosition(onset.frameLength), frameCount: count - onset.frameLength, at: nil, completionHandler: nil)
        }
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
        let settings = track.timecode ?? TimecodeSettings()
        let position = transport.playing || transport.paused == true ? transport.position : transport.editPosition ?? transport.position
        let span = TimecodePlaybackSpan(song: song, track: track, position: position, settings: settings, preferredRegion: transport.regionId)
        let now = ProcessInfo.processInfo.systemUptime
        let delay = span?.delay ?? 0
        let time = span?.time ?? position + settings.offset
        let end = span?.end ?? time
        let active = transport.playing && span != nil && !track.mute
        let mode = track.mute || span == nil ? "" : settings.mode
        let destination = AudioDeviceSettings.shared.resolvedMIDIDestination(settings.midiDestination)
        let key = "\(span?.clip.id.uuidString ?? "")-\(span?.clip.startTime ?? 0)-\(active)-\(mode)-\(settings.frameRate)-\(destination)-\(settings.regionRelative)-\(settings.offset)-\(end)"
        let changed = timecodeAnchor.map { $0.key != key || (!mode.isEmpty && abs(time - ($0.position + (active ? now + delay - $0.host : 0))) > (active ? 0.08 : 0.000001)) } ?? true
        if changed {
            timecodeGenerator?.configurePosition(time, end: end, hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: delay), rate: settings.frameRate, mode: mode, running: active, destination: destination)
            timecodeAnchor = (key,time,now + delay)
        }
        if timecodePreviewGain?.original != track.volume { timecodePreviewGain = nil }
        timecodeGenerator?.setGain(timecodePreviewGain?.value ?? Float(track.volume))
        configureRoutes(timecodeRoutes, patches: mode == "ltc" && !masterSolo ? track.outputPatches : [])
        if let slot = slots[track.id] {
            let peak = active && mode == "ltc" ? timecodeGenerator?.takePeak() ?? 0 : 0
            peaks.recordPeak(peak, slot: UInt(slot)); peaks.recordPeak(peak, slot: UInt(slot + 1))
            if mode != "ltc" || !active { meters[track.id]?.reset() }
        }
    }
    private func applyMultiLoopMix(_ snapshot: ShowSnapshot, song: Song) {
        let loop = snapshot.transport.multiLoop
        let rules = Dictionary(uniqueKeysWithValues: (loop?.tracks ?? []).filter { $0.autoFader || $0.mute || $0.solo }.map { ($0.id, $0) })
        let next = Set(rules.keys)
        let affected = multiLoopTargets.union(next)
        guard !affected.isEmpty else { return }
        let gates = loop?.gates == true
        for track in song.tracks where affected.contains(track.id) && track.kind != .timecode {
            let rule = rules[track.id]
            let gain = loop?.gain(track.volume, rule: rule) ?? track.volume
            let mute = track.mute || (gates && rule?.mute == true)
            let solo = track.solo || (gates && rule?.solo == true)
            if tracks[track.id]?.volume != gain { previewVolume(track.id, gain: gain) }
            if tracks[track.id]?.mute != mute { previewMute(track.id, muted: mute) }
            if tracks[track.id]?.solo != solo { previewSolo(track.id, solo: solo) }
        }
        if affected.contains(MultiLoopTrack.masterID) {
            let rule = rules[MultiLoopTrack.masterID]
            let gain = loop?.gain(snapshot.project.masterVolume ?? 1, rule: rule) ?? snapshot.project.masterVolume ?? 1
            let mute = snapshot.project.masterMute == true || (gates && rule?.mute == true)
            let solo = snapshot.project.masterSolo == true || (gates && rule?.solo == true)
            if master != gain { previewVolume(nil, gain: gain) }
            if masterMuted != mute { previewMute(nil, muted: mute) }
            if masterSolo != solo { previewMasterSolo(solo) }
        }
        multiLoopTargets = next
    }
    func refreshMetronome() {
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
        metronome.configurePosition(transport.position, hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.02), running: settings.enabled && transport.playing,
            loopStart: transport.loop.enabled ? transport.loop.start ?? 0 : 0, loopEnd: transport.loop.enabled ? transport.loop.end ?? 0 : 0)
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
            for head in Array(lastPosition.keys) { lastPosition[head]! *= timelineScale }
        }
        tempo = song.bpm
        #if os(macOS)
        for chain in [masterEffects] + trackBuses.values.map(\.effects) { chain.externalTransport(position: transport.position, tempo: song.bpm, beats: Int32(song.meterBeats), unit: Int32(song.meterUnit), playing: transport.playing) }
        #endif
        if self.revision != revision || songID != song.id || lastVideoNoAudio != VideoMediaSettings.shared.noAudio {
            lastVideoNoAudio = VideoMediaSettings.shared.noAudio
            if songID != song.id { stop() }
            if song.tracks.contains(where: { tracks[$0.id]?.midiInput != $0.midiInput || tracks[$0.id]?.midiChannel != $0.midiChannel }) { releaseMIDINotes() }
            tracks = Dictionary(uniqueKeysWithValues: song.tracks.filter { $0.kind == .standard || $0.kind == .video }.map { ($0.id, $0) })
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
            let metered = song.tracks.filter { $0.kind == .standard || $0.kind == .timecode || $0.kind == .video }
            let activeIDs = Set(metered.map(\.id))
            slots = slots.filter { activeIDs.contains($0.key) }
            var usedSlots = Set(slots.values)
            for track in metered where slots[track.id] == nil {
                if let slot = (0..<400).map({ $0 * 2 }).first(where: { !usedSlots.contains($0) }) { slots[track.id] = slot; usedSlots.insert(slot) }
            }
            // Prepare routing before Play so starting a file only adds its source.
            for track in song.tracks where track.kind == .standard || track.kind == .video { _ = trackBus(for: track.id) }
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
                      current.1.audioFile?.path == voice.clip.audioFile?.path else { remove(key); continue }
                // A scheduled future onset has a wall-clock deadline, so only
                // that pending voice needs a new deadline after a tempo edit.
                let position = key.head == 0 ? transport.position : transport.subPlay.position
                if tempoChanged && current.1.startTime > position { remove(key); continue }
                if current.1.audioRate != voice.clip.audioRate {
                    voice.stretch.rate = Float(current.1.audioRate)
                }
                var updated = voice
                updated.clip = current.1
                applyClipFX(current.1.fx ?? emptyFX, to: &updated)
                voices[key] = updated

            }
            for key in Array(effectTails.keys) {
                guard var tail = effectTails[key], let current = byID[key.clip], current.0 == tail.voice.track else {
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
                (clip.id, Float(song.pitch(for: track, region: song.pitchRegion(at: fragmentStarts[clip.id] ?? clip.startTime)) * 100))
            })
        }
        if running { cancelVoicePreparation() }
        transportWasRunning = running
        setGraphRenderEnabled(running || instrumentRenderPending)
        applyMultiLoopMix(snapshot, song: song)
        updateMetronome(song: song, transport: transport)
        updateTimecode(song: transport.multiLoop?.projectionSong(song) ?? song, transport: transport)
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
            lastPosition[0] = lastPosition[1]
            lastPosition[1] = nil
        }
        for (head, playing, position) in [(0, transport.playing, transport.position), (1, transport.subPlay.playing, transport.subPlay.position)] {
            if !playing {
                clearEffectTails(head: head)
                for key in Array(voices.keys) where key.head == head { remove(key) }
                lastPosition[head] = nil
                continue
            }
            if let previous = lastPosition[head], abs(position - previous - elapsed) > 0.15 {
                clearEffectTails(head: head)
                for key in Array(voices.keys) where key.head == head { remove(key) }
            }
            lastPosition[head] = position
            let regionID = head == 0 ? transport.regionId : transport.queuedRegionId
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
            for key in Array(voices.keys) where key.head == head {
                if let voice = voices[key], voice.clip.startTime + voice.clip.duration <= position { remove(key, keepingTailAt: position) }
            }
            for key in Array(effectTails.keys) where key.head == head {
                if let tail = effectTails[key], position >= tail.until {
                    effectTails[key] = nil; recycle(tail.voice)
                }
            }
            for key in voices.keys where key.head == head {
                if let voice = voices[key] {
                    let cents = clipPitches[voice.clip.id] ?? 0
                    if voice.stretch.pitch != cents { voice.stretch.pitch = cents }
                }
            }
            let prepareEnd: Double? = head == 0 && snapshot.project.regionSetlist?.preparesWithoutPlayback == true && transport.queuedRegionId != nil
                ? song.parts.first(where: { $0.id == transport.regionId }).map { part in
                    part.parentRegionID.flatMap { id in song.parts.first(where: { $0.id == id }) }?.endTime ?? part.endTime
                } : nil
            var scheduled: [(AVAudioPlayerNode, Double)] = []
            for (track, clip) in clips where clip.startTime <= position + 0.5 && clip.startTime + clip.duration > position {
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
                var voice = takeVoice(track: track, clip: clip, file: file)
                let player = voice.player
                voice.stretch.rate = Float(clip.audioRate)
                voice.stretch.pitch = clipPitches[clip.id] ?? 0
                var scheduledUntil = clip.startTime + clip.duration
                if clip.loopLength != nil {
                    scheduledUntil = try scheduleLoop(file: file, player: player, clip: clip, from: max(clip.startTime, position), until: max(clip.startTime, position) + 5, onset: true)
                } else { try scheduleStart(file: file, player: player, first: first, count: AVAudioFrameCount(count)) }
                voice.scheduledUntil = scheduledUntil
                voices[key] = voice
                scheduled.append((player, max(0, clip.startTime - position)))
            }
            if !engine.isRunning { engine.prepare(); try engine.start() }
            startMeterClock()
            if !scheduled.isEmpty { applyLevels() }
            let startHost = mach_absolute_time()
            for (player, delay) in scheduled {
                if realtime { player.play(at: AVAudioTime(hostTime: startHost + AVAudioTime.hostTime(forSeconds: delay + 0.02))) }
                else { player.play() }
            }
        }
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
            for slot in slots.values { _ = peaks.takePeak(UInt(slot)); _ = peaks.takePeak(UInt(slot + 1)) }
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
            for (id, slot) in slots {
                let left = Double(peaks.takePeak(UInt(slot))), right = Double(peaks.takePeak(UInt(slot + 1)))
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

@MainActor final class NativeVerticalTrackMeterView: NSView {
    private weak var meter: TrackMeterLevel?
    private var subscription: AnyCancellable?
    private var peakSubscription: AnyCancellable?
    private var peakDB: Double?
    private var levels = SIMD2<Double>(repeating: 0)
    private var showScale = false
    private var pendingDrawing = true
    private weak var observedClip: NSClipView?
    private weak var clipObserver: NativeMeterClipObserver?
    private static let gradient = NSGradient(colors: [NSColor(Color.green), NSColor(Color.yellow), NSColor(Color.red)])!
    private static let scaleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular),
        .foregroundColor: NSColor(red: 0x9a / 255.0, green: 0xa8 / 255.0, blue: 0xb9 / 255.0, alpha: 1)
    ]
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityRole(.image)
        setAccessibilityLabel("Stereo meter, L and R")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func bind(_ meter: TrackMeterLevel, showScale: Bool) {
        if self.showScale != showScale { self.showScale = showScale; pendingDrawing = true }
        if self.meter !== meter {
            self.meter = meter
            peakSubscription = meter.peakHold.$decibels.sink { [weak self] value in
                guard let self, self.peakDB != value else { return }
                self.peakDB = value; self.pendingDrawing = true; self.refreshVisibleDrawing()
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
        super.viewDidMoveToWindow(); updateClipObserver(); refreshVisibleDrawing()
    }
    private func updateClipObserver() {
        let clip = enclosingScrollView?.contentView
        guard clip !== observedClip else { return }
        clipObserver?.remove(self); observedClip = clip
        clipObserver = clip.map { NativeMeterClipObserver.forClip($0) }
        clipObserver?.add(self)
    }
    fileprivate func refreshVisibleDrawing() {
        guard pendingDrawing, let window, window.isVisible, !window.isMiniaturized,
              !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        pendingDrawing = false
        let width: CGFloat = 4.5
        for channel in 0..<2 {
            let rect = NSRect(x: CGFloat(channel) * (width + 1), y: 0, width: width, height: bounds.height)
            NSColor.black.withAlphaComponent(0.55).setFill(); rect.fill()
            let level = levels[channel]
            let fraction = level > 0 && level.isFinite ? min(1, max(0, (20 * log10(level) + 60) / 60)) : 0
            guard fraction > 0, let context = NSGraphicsContext.current?.cgContext else { continue }
            context.saveGState()
            context.clip(to: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * fraction))
            Self.gradient.draw(in: rect, angle: 90)
            context.restoreGState()
        }
        if showScale {
            if let peakDB {
                let text = String(format: "%+.2f", peakDB) as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .bold), .foregroundColor: NSColor.systemRed]
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: 13, y: max(0, bounds.height - size.height) * 0.75), withAttributes: attributes)
            }
            for (text, fraction) in [("0", 1.0), ("−24", 0.5), ("−60", 0.0)] {
                let text = text as NSString, size = text.size(withAttributes: Self.scaleAttributes)
                let x = 13 + max(0, (bounds.width - 13 - size.width) / 2)
                text.draw(at: NSPoint(x: x, y: max(0, bounds.height - size.height) * fraction), withAttributes: Self.scaleAttributes)
            }
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
                    Text("−60")
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
