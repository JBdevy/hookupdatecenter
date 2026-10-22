import SwiftUI
import Combine
import AVFoundation
#if os(macOS)
import CoreAudio
import AudioToolbox
#endif

private struct CaptureTarget: Sendable {
    let track: UUID
    let input: OutputPatch
    let format: String
    var name = "Recording"
    var id = UUID()
    var lane = 0
    var recordedChannels: Int? = nil
    var postFader = true
    var postFX = true
    var gain: Float = 1
    var effects: NativeFXSettings? = nil
    var channelCount: Int { recordedChannels ?? input.channelCount }
}
private struct CapturedItem: Sendable { let track: UUID; let clip: AudioClip }

/// A single writer queue consumes preallocated PCM from the realtime ring.
private final class CaptureWriter: @unchecked Sendable {
    let ring: JarasCaptureRing
    private let queue = DispatchQueue(label: "live.jaras.recording.writer", qos: .userInitiated)
    private let channels: Int
    private let sampleRate: Double
    private let directory: URL
    private var interleaved: [Float]
    private var takes: [Take] = []
    private let pendingFiles = DispatchGroup()
    private var timer: DispatchSourceTimer?
    private var frames: Int64 = 0
    private var failure: Error?
    private var lastPreview = 0.0
    private var preview: (@Sendable (Double,[UUID:[[Double]]]) -> Void)?
    var takePreview: (@Sendable ([UUID: Double], [UUID: LiveRecordedWaveform]) -> Void)?
    private final class Take {
        let target: CaptureTarget
        let url: URL
        var file: AVAudioFile?
        let buffer: AVAudioPCMBuffer
        var overview: RecordingOverview
        let waveform: LiveRecordedWaveform
        var frames: Int64 = 0
        var writtenFrames: Int64 = 0
        var processor: RecordingInputProcessor?
        var skipFrames: Int
        var gain: Float
        var position: Double?
        var droppedFramesAtStart: UInt = 0
        init(target: CaptureTarget,url: URL,file: AVAudioFile,buffer: AVAudioPCMBuffer, mediaDirectory: URL) throws {
            self.target=target; self.url=url; self.file=file; self.buffer=buffer
            gain = target.postFader ? target.gain : 1
            if target.postFX, let settings = target.effects,
               settings.effectKeys.contains(where: { settings.isEnabled($0) }) {
                processor = try RecordingInputProcessor(format: buffer.format, settings: settings, mediaDirectory: mediaDirectory)
            } else { processor = nil }
            skipFrames = processor?.latency ?? 0
            waveform = try LiveRecordedWaveform(rate: buffer.format.sampleRate, channels: target.channelCount)
            overview=RecordingOverview(channels: target.channelCount,sampleRate: buffer.format.sampleRate)
        }
    }
    init(targets: [CaptureTarget], directory: URL, format: AVAudioFormat, ring: JarasCaptureRing? = nil) throws {
        self.directory = directory; channels = Int(format.channelCount); sampleRate = format.sampleRate
        self.ring = ring ?? JarasCaptureRing(channels: UInt(channels), capacity: UInt(sampleRate * 8))
        interleaved = Array(repeating: 0, count: 4096 * channels)
        for target in targets { takes.append(try makeTake(target)) }
    }
    private func makeTake(_ target: CaptureTarget) throws -> Take {
        let folder = directory.appendingPathComponent("Stems", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard target.input.firstChannel >= 1, target.input.firstChannel + target.input.channelCount - 1 <= channels else { throw ProjectError.invalid("Selected recording input is unavailable.") }
            let aiff = target.format.hasPrefix("aiff")
            let url = folder.appendingPathComponent(target.name).appendingPathExtension(aiff ? "aiff" : "wav")
            try Data().write(to: url, options: .withoutOverwriting)
            let settings: [String: Any] = [AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:sampleRate, AVNumberOfChannelsKey:target.channelCount, AVLinearPCMBitDepthKey:target.format.hasSuffix("16pcm") ? 16 : (target.format == "wav32" || target.format.hasSuffix("32pcm")) ? 32 : 24, AVLinearPCMIsFloatKey:target.format == "wav32", AVLinearPCMIsBigEndianKey:aiff, AVLinearPCMIsNonInterleaved:false]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { throw ProjectError.invalid("Could not allocate recording buffer") }
        let take = try Take(target: target, url: url, file: file, buffer: buffer, mediaDirectory: directory)
        take.droppedFramesAtStart = ring.droppedFrames
        return take
    }
    func setInitialPosition(_ position: Double) { for take in takes { take.position = position } }
    func changeTargets(_ targets: [CaptureTarget], position: Double, completion: @escaping @Sendable ([CapturedItem], String?) -> Void) {
        queue.async {
            self.drain()
            let ids = Set(targets.map(\.track))
            let removed = self.takes.filter { !ids.contains($0.target.track) }
            self.takes.removeAll { !ids.contains($0.target.track) }
            self.finalize(removed, fallbackStart: position, completion: completion)
            do {
                for target in targets where !self.takes.contains(where: { $0.target.track == target.track }) {
                    let take = try self.makeTake(target); take.position = position; self.takes.append(take)
                }
            } catch { completion([], error.localizedDescription) }
        }
    }
    func start(preview: (@Sendable (Double,[UUID:[[Double]]]) -> Void)? = nil) {
        ring.beginCapture()
        queue.async {
            // beginCapture resets the shared ring's loss counter. Initial
            // takes belong to this new session, even if the ring was reused.
            for take in self.takes { take.droppedFramesAtStart = 0 }
            self.preview = preview
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(3))
            timer.setEventHandler { [weak self] in self?.drain() }
            self.timer = timer; timer.resume()
        }
    }
    private func drain() {
        while true {
            let count = interleaved.withUnsafeMutableBufferPointer { ring.readFrames($0.baseAddress!, maximum: 4096) }
            if count == 0 {
                let time = Double(frames)/sampleRate
                if time-lastPreview >= 0.08 { lastPreview=time; takePreview?(Dictionary(uniqueKeysWithValues: takes.map { ($0.target.id, Double($0.frames)/sampleRate) }), Dictionary(uniqueKeysWithValues: takes.map { ($0.target.id, $0.waveform) })); preview?(time,Dictionary(uniqueKeysWithValues: takes.map { ($0.target.track,$0.overview.snapshot) })) }
                return
            }
            guard failure == nil else { continue }
            do {
                for take in takes {
                    take.buffer.frameLength = AVAudioFrameCount(count)
                    for frame in 0..<Int(count) {
                        for channel in 0..<take.target.channelCount {
                            let sample = interleaved[frame * channels + take.target.input.firstChannel - 1 + min(channel, take.target.input.channelCount - 1)]
                            take.buffer.floatChannelData![channel][frame] = sample
                        }
                    }
                    take.frames += Int64(count)
                    try process(take)
                }
                frames += Int64(count)
            } catch { failure = error }
        }
    }
    // Fader edits are serialized after previously captured PCM. The recording
    // graph remains independent from the track's playback and monitoring graph.
    func updateGains(_ gains: [UUID: Float]) {
        queue.async {
            self.drain()
            for take in self.takes where take.target.postFader {
                if let gain = gains[take.target.track] { take.gain = gain }
            }
        }
    }
    func updateEffects(_ track: UUID, settings: NativeFXSettings) {
        queue.async {
            self.drain()
            do {
                for take in self.takes where take.target.track == track && take.target.postFX {
                    // Finish PCM already inside the old chain before a latency
                    // change; otherwise removing a lookahead FX shifts the take.
                    try self.flushLatency(take)
                    if let processor = take.processor { try processor.update(settings) }
                    else { take.processor = try RecordingInputProcessor(format: take.buffer.format, settings: settings, mediaDirectory: self.directory) }
                    take.skipFrames = take.processor?.latency ?? 0
                }
            } catch { self.failure = error }
        }
    }
    private func process(_ take: Take) throws {
        try take.processor?.process(take.buffer)
        let count = Int(take.buffer.frameLength)
        let skip = min(count, take.skipFrames); take.skipFrames -= skip
        let kept = min(count - skip, Int(take.frames - take.writtenFrames))
        guard kept > 0 else { return }
        for channel in 0..<take.target.channelCount {
            let data = take.buffer.floatChannelData![channel]
            for frame in 0..<kept { data[frame] = data[frame + skip] * take.gain }
        }
        take.buffer.frameLength = AVAudioFrameCount(kept)
        if preview != nil {
            for frame in 0..<kept {
                for channel in 0..<take.target.channelCount { take.overview.append(take.buffer.floatChannelData![channel][frame], channel: channel) }
                take.overview.endFrame()
            }
        }
        try take.file?.write(from: take.buffer)
        try take.waveform.append(take.buffer)
        take.writtenFrames += Int64(kept)
    }
    private func flushLatency(_ take: Take) throws {
        while take.processor != nil && take.writtenFrames < take.frames {
            let count = min(4096, Int(take.frames - take.writtenFrames) + take.skipFrames)
            take.buffer.frameLength = AVAudioFrameCount(count)
            for ch in 0..<take.target.channelCount { take.buffer.floatChannelData![ch].update(repeating: 0, count: count) }
            try process(take)
        }
    }
    private func finalize(_ completed: [Take], fallbackStart: Double, completion: @escaping @Sendable ([CapturedItem], String?) -> Void) {
        guard !completed.isEmpty else { return }
        for take in completed {
            do {
                // Recover the delayed end of the input, retaining the exact
                // captured length. Reverb tails beyond REC are not appended.
                try flushLatency(take)
            } catch { self.failure = error }
            take.file = nil
        }
        let failure = self.failure?.localizedDescription
        let dropped = ring.droppedFrames
        let lostAudio = completed.contains { dropped > $0.droppedFramesAtStart }
        pendingFiles.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.pendingFiles.leave() }
            var items: [CapturedItem] = [], message = failure
            for take in completed {
                guard take.frames > 0 else {
                    try? FileManager.default.removeItem(at: take.url)
                    message = message ?? "No audio was received from the recording input."
                    continue
                }
                var url = take.url
                if take.target.format.hasPrefix("mp3") {
                    let mp3 = url.deletingPathExtension().appendingPathExtension("mp3")
                    do { let source = try AVAudioFile(forReading: url)
                        let encoder = try JarasMP3StreamEncoder(url: mp3, sampleRate: Int(source.processingFormat.sampleRate), channels: Int(source.processingFormat.channelCount), bitRate: Int(take.target.format.split(separator: "-").last ?? "320") ?? 320)
                        let pcm = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096)!
                        while source.framePosition < source.length { try source.read(into: pcm, frameCount: 4096); try encoder.write(pcm) }
                        try encoder.finish(); url = mp3; try? FileManager.default.removeItem(at: take.url) }
                    catch { message = error.localizedDescription; try? FileManager.default.removeItem(at: mp3) }
                }
                do {
                    let duration = Double(take.frames) / self.sampleRate
                    let overview = try StemProjectImporter.audioOverview(url, duration: duration)
                    let clip = AudioClip(id: take.target.id, name: take.target.name, startTime: take.position ?? fallbackStart, duration: duration, waveform: overview.waveform,
                        audioFile: AudioFile(path: "Stems/" + url.lastPathComponent), waveformChannels: overview.channels, recordingLane: take.target.lane)
                    items.append(CapturedItem(track: take.target.track, clip: clip))
                } catch { message = error.localizedDescription }
            }
            if lostAudio && !items.isEmpty {
                let warning = JarasLocalization.string("Some audio was lost during recording. The captured audio was preserved, but the recording may be incomplete.")
                message = [message, warning].compactMap { $0 }.joined(separator: "\n")
            }
            completion(items, message)
        }
    }
    func finish(start: Double, completion: @escaping @Sendable ([CapturedItem], String?) -> Void) {
        ring.endCapture()
        queue.async {
            self.ring.waitForPendingCapture()
            self.timer?.cancel(); self.timer = nil; self.drain()
            let completed = self.takes; self.takes = []
            // Finalizers run away from the writer, so one MP3 conversion never
            // stalls the remaining armed tracks or the device callback.
            self.finalize(completed, fallbackStart: start) { items, error in
                self.pendingFiles.notify(queue: self.queue) { completion(items, error) }
            }
            if completed.isEmpty { self.pendingFiles.notify(queue: self.queue) { completion([], nil) } }
        }
    }

}

@MainActor final class TrackRecording: ObservableObject {
    static var shared = TrackRecording()
    weak var projectAudio: StemAudioPlayback?
    private var projectTabActive = true
    @Published private(set) var armed: Set<UUID> = []
    @Published private(set) var armState = RecordingArmState()
    private var microphoneTracks: Set<UUID> = []
    private var selectionObservation: AnyCancellable?
    private var requestingMicrophone = false
    #if os(iOS)
    private var localAudioAvailable = false
    private var mobileCaptureStop: MobileAudioHardwareStop?
    func setLocalAudioAvailable(_ available: Bool) {
        localAudioAvailable = available
        if available { reconcileArming() }
        else { finish(); releaseInput() }
    }
    func waitForLocalHardwareSuspension() async throws {
        guard let pending = mobileCaptureStop else { return }
        do { try await pending.wait() }
        catch is CancellationError { throw CancellationError() }
        catch { throw ProjectError.invalid(JarasLocalization.string("Audio device is unavailable. Reconnect it or choose an output in Settings.")) }
        if mobileCaptureStop === pending {
            mobileCaptureStop = nil
            finishInputRelease()
        }
    }
    #endif
    func suspendProjectTab() { projectTabActive = false; releaseInput() }
    func bind(_ show: ShowController) {
        projectTabActive = true;
        self.show = show
        AudioDeviceSettings.shared.canChangeConfiguration = { [weak self] in
            self?.recording != true && self?.busy != true
        }
        AudioDeviceSettings.shared.inputDeviceChanged = { [weak self] in
            guard let self else { return }
            if self.recording { self.finish() }
            self.releaseInput(); self.configuredInput = 0
            self.reconcileArming()
        }
        ControlMappings.shared.onMIDIReceived = { [weak self] device, status, number, value, timestamp in
            self?.receiveMIDI(device: device, status: status, number: number, value: value, timestamp: timestamp)
        }
        (projectAudio ?? StemAudioPlayback.shared).onRecordingFXChanged = { [weak self] track, settings in
            self?.writer?.updateEffects(track, settings: settings)
        }
        (projectAudio ?? StemAudioPlayback.shared).onLiveKeyboardMIDI = { [weak self] track, status, number, value in
            guard let self, self.recording else { return }
            let position = self.startPosition + ProcessInfo.processInfo.systemUptime - self.midiStartTime
            self.midiTakes[track]?.receive(source: Int32.min, status: status, number: number, value: value, position: position)
        }
        selectionObservation = show.$mixerTrackSelection.removeDuplicates().sink { [weak self] selection in
            guard let self else { return }
            self.armState.select(selection)
            self.reconcileArming()
        }
    }
    @Published private(set) var recording = false
    @Published private(set) var busy = false
    @Published var error = ""
    #if os(iOS)
    private let mobileInput = JarasMobileAudioInput()
    private var inputEngineRunning: Bool { mobileInput.running }
    #else
    private let captureEngine = AVAudioEngine()
    private var inputEngineRunning: Bool { captureEngine.isRunning }
    #endif
    private func captureFormat() throws -> AVAudioFormat {
        #if os(iOS)
        guard let format = mobileInput.format else {
            throw ProjectError.invalid(JarasLocalization.string("No audio inputs available."))
        }
        return format
        #else
        return captureEngine.inputNode.outputFormat(forBus: 0)
        #endif
    }
    private var captureRing: JarasCaptureRing?
    private struct MonitorConfig: Equatable { let track: UUID; let patch: OutputPatch; let channels: Int }
    private var monitorConfig: [MonitorConfig] = []
    private var monitorRings: [JarasCaptureRing] = []
    private var tapInstalled = false
    private var updatingMonitoring = false
    private func refreshMonitoring() {
        #if os(iOS)
        guard localAudioAvailable, !AudioDeviceSettings.shared.localSessionReconfiguring else { return }
        #endif
        guard !updatingMonitoring else { return }
        updatingMonitoring = true; defer { updatingMonitoring = false }
        let tracks = show?.current?.tracks ?? []
        (projectAudio ?? StemAudioPlayback.shared).armedMIDIRecordingTracks = Set(tracks.filter { armed.contains($0.id) && $0.recordingMode == .midi }.map(\.id))
        let desired = inputChannels > 0 && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? tracks.filter {
            armed.contains($0.id) && $0.recordingMode != .midi && $0.kind == .standard
        }.map { MonitorConfig(track: $0.id, patch: $0.inputPatch ?? defaultInputPatch, channels: $0.recordingChannels ?? 2) } : []
        let playback = (projectAudio ?? StemAudioPlayback.shared)
        guard desired != monitorConfig || desired.contains(where: { !playback.hasInputMonitor($0.track) }) else { return }
        for config in monitorConfig { playback.setInputMonitor(config.track, source: nil) }
        monitorConfig = []; monitorRings = []
        guard !desired.isEmpty else { rebuildInputTap(); releaseInputIfIdle(); return }
        do { try configureInput() }
        catch { self.error = error.localizedDescription; releaseInput(); return }
        guard let format = try? captureFormat() else { releaseInput(); return }
        guard format.channelCount > 0, format.sampleRate > 0 else { releaseInput(); return }
        for config in desired where config.patch.firstChannel >= 1 && config.patch.firstChannel + config.patch.channelCount - 1 <= Int(format.channelCount) {
            let ring = JarasCaptureRing(channels: UInt(format.channelCount), capacity: UInt(max(8192, format.sampleRate / 4)))
            let count = min(config.channels, config.patch.channelCount)
            let source = ring.monitorSource(withSampleRate: format.sampleRate, firstChannel: UInt(config.patch.firstChannel - 1), channelCount: UInt(count))
            playback.setInputMonitor(config.track, source: source, format: AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(count)), input: ring, firstChannel: config.patch.firstChannel - 1, channels: count)
            monitorConfig.append(config); monitorRings.append(ring)
        }
        if captureRing == nil {
            captureRing = JarasCaptureRing(channels: UInt(format.channelCount), capacity: UInt(format.sampleRate * 8))
            captureRing?.endCapture()
        }
        rebuildInputTap()
        do { try startInputEngine() }
        catch { self.error = error.localizedDescription; releaseInput() }
    }
    private func rebuildInputTap() {
        guard tapInstalled || captureRing != nil else { return }
        #if os(iOS)
        let wasRunning = mobileInput.running
        mobileInput.pause()
        mobileInput.setCapture(nil); tapInstalled = false
        guard let ring = captureRing else { return }
        let rings = monitorRings
        let capture: @Sendable (AVAudioPCMBuffer) -> Void = { buffer in
            ring.push(buffer)
            for monitor in rings { monitor.push(buffer) }
        }
        mobileInput.setCapture(capture)
        tapInstalled = true
        if wasRunning {
            do { try mobileInput.start() } catch { self.error = error.localizedDescription }
        }
        #else
        let input = captureEngine.inputNode
        if tapInstalled { input.removeTap(onBus: 0); tapInstalled = false }
        guard let ring = captureRing else { return }
        let rings = monitorRings
        input.installTap(onBus: 0, bufferSize: 256, format: input.outputFormat(forBus: 0)) { buffer, _ in
            ring.push(buffer)
            for monitor in rings { monitor.push(buffer) }
        }
        tapInstalled = true
        #endif
    }
    private var configuredInput: UInt32 = 0
    private var directory: URL?
    private var project: UUID?
    private var writer: CaptureWriter?
    private var activeTargets: [UUID: CaptureTarget] = [:]
    private var midiTakes: [UUID: MIDIRecordingTake] = [:]
    private var midiStartTime = 0.0
    private var recordingSong: UUID?
    private var recordingNames = RecordingNames(directory: nil)
    private var pendingTakes = Set<UUID>()
    private weak var show: ShowController?
    private var startPosition = 0.0
    private var previewSession = UUID()
    private var lastPosition = 0.0
    private var lastTime = 0.0
    var defaultInputPatch: OutputPatch { OutputPatch(firstChannel: 1, channelCount: min(2, max(1, inputChannels))) }
    var inputChannels: Int { AudioDeviceSettings.shared.inputDevice?.channels ?? 0 }
    private func configureInput(allowCaptureSetup: Bool = false) throws {
        #if os(macOS)
        let audio = AudioDeviceSettings.shared
        guard let device = audio.inputDevice, device.hardwareID != 0 else {
            releaseInput(); configuredInput = 0
            throw ProjectError.invalid(JarasLocalization.string("Choose an audio input device in Settings."))
        }
        var selected = device.hardwareID
        let canConfigure = (!recording && !busy) || (allowCaptureSetup && writer == nil)
        guard selected == configuredInput || canConfigure else {
            throw ProjectError.invalid(JarasLocalization.string("The audio input changed while preparing the recording. Start recording again."))
        }
        guard let unit = captureEngine.inputNode.audioUnit else {
            throw ProjectError.invalid(JarasLocalization.string("No audio inputs available."))
        }
        // A remembered selection does not prove which hardware this unit uses.
        // Verify the actual route before reusing an existing input configuration.
        let actual = try actualInputDevice(unit)
        guard selected != configuredInput || actual != selected else { return }
        guard canConfigure else {
            throw ProjectError.invalid(JarasLocalization.string("The audio input changed while preparing the recording. Start recording again."))
        }
        releaseInput(); configuredInput = 0
        let result = AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&selected,UInt32(MemoryLayout<UInt32>.size))
        guard result == noErr else {
            throw ProjectError.invalid(JarasLocalization.string("Could not open the selected audio input device.") + " (\(result))")
        }
        guard try actualInputDevice(unit) == selected else {
            throw ProjectError.invalid(JarasLocalization.string("Could not open the selected audio input device."))
        }
        configuredInput = selected
        #else
        guard localAudioAvailable else {
            throw ProjectError.invalid(JarasLocalization.string("Open Native mode to record audio."))
        }
        try AudioDeviceSettings.shared.requireLocalInput()
        let session = AVAudioSession.sharedInstance()
        try mobileInput.prepare(withSampleRate: session.sampleRate, channels: AVAudioChannelCount(session.inputNumberOfChannels))
        #endif
    }
    #if os(macOS)
    private func actualInputDevice(_ unit: AudioUnit) throws -> UInt32 {
        var actual: UInt32 = 0, bytes = UInt32(MemoryLayout<UInt32>.size)
        let result = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &bytes)
        guard result == noErr else {
            throw ProjectError.invalid(JarasLocalization.string("Could not open the selected audio input device.") + " (\(result))")
        }
        guard bytes == UInt32(MemoryLayout<UInt32>.size) else {
            throw ProjectError.invalid(JarasLocalization.string("Could not open the selected audio input device."))
        }
        return actual
    }
    #endif
    private func requireConfiguredInput(expectedUID: String? = nil, expectedDevice: UInt32? = nil) throws {
        #if os(macOS)
        let audio = AudioDeviceSettings.shared
        guard let device = audio.inputDevice, device.hardwareID != 0 else {
            throw ProjectError.invalid(JarasLocalization.string("Choose an audio input device in Settings."))
        }
        guard configuredInput == device.hardwareID,
              expectedUID == nil || expectedUID == audio.inputUID,
              expectedDevice == nil || expectedDevice == device.hardwareID else {
            throw ProjectError.invalid(JarasLocalization.string("The audio input changed while preparing the recording. Start recording again."))
        }
        guard let unit = captureEngine.inputNode.audioUnit,
              try actualInputDevice(unit) == device.hardwareID else {
            throw ProjectError.invalid(JarasLocalization.string("The audio input changed while preparing the recording. Start recording again."))
        }
        #else
        guard localAudioAvailable else {
            throw ProjectError.invalid(JarasLocalization.string("Open Native mode to record audio."))
        }
        try AudioDeviceSettings.shared.requireLocalInput(expectedUID: expectedUID)
        #endif
    }
    private func startInputEngine() throws {
        try requireConfiguredInput()
        #if os(iOS)
        try mobileInput.start()
        #else
        if !captureEngine.isRunning { captureEngine.prepare(); try captureEngine.start() }
        #endif
    }
    func open(directory: URL, project: UUID) {
        if recording { finish() }
        releaseInput()
        self.directory = directory; self.project = project; recordingNames = RecordingNames(directory: directory, clips: show?.snapshot.project.songs.flatMap(\.tracks).flatMap(\.clips) ?? []); armed.removeAll(); armState = RecordingArmState(); microphoneTracks.removeAll(); midiTakes.removeAll(); LiveRecordingPreview.shared.takes = [:]; RecordingLaneLayout.shared.clear()
    }
    func closeProject() {
        guard !recording, !busy else { return }
        releaseInput(); directory = nil; project = nil; armed.removeAll(); armState = RecordingArmState(); microphoneTracks.removeAll(); midiTakes.removeAll()
        LiveRecordingPreview.shared.takes = [:]; RecordingLaneLayout.shared.clear()
    }
    func toggleArm(_ track: UUID, requiresAudioInput: Bool = true) {
        setMode(armState.mode(for: track).next, tracks: [track], requiresAudioInput: requiresAudioInput)
    }
    func setArmed(_ tracks: Set<UUID>, active: Bool, requiresAudioInput: Bool) {
        setMode(active ? .manual : .off, tracks: tracks, requiresAudioInput: requiresAudioInput)
    }
    func setMode(_ mode: RecordingArmState.Mode, tracks: Set<UUID>, requiresAudioInput: Bool) {
        guard !busy else { return }
        if requiresAudioInput { microphoneTracks.formUnion(tracks) } else { microphoneTracks.subtract(tracks) }
        armState.select(show?.mixerTrackSelection ?? [])
        armState.set(mode, tracks: tracks)
        reconcileArming()
    }
    private func reconcileArming() {
        guard projectTabActive else { return }
        #if os(iOS)
        guard localAudioAvailable else { return }
        #endif
        guard !busy else { return }
        let wanted = armState.armed
        if let show {
            microphoneTracks = wanted.intersection(Set(show.snapshot.project.songs.flatMap(\.tracks).filter { $0.recordingMode != .midi }.map(\.id)))
        }
        let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        let effective = authorization == .authorized || inputChannels == 0 ? wanted : wanted.subtracting(microphoneTracks)
        if armed != effective { armed = effective; updateArmedTargets() }
        refreshMonitoring()
        guard inputChannels > 0, !wanted.intersection(microphoneTracks).isEmpty, authorization != .authorized else { return }
        guard authorization == .notDetermined else {
            error = "Allow microphone access in System Settings to record audio."; return
        }
        guard !requestingMicrophone else { return }
        requestingMicrophone = true
        let requestedProject = project
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            requestingMicrophone = false
            guard project == requestedProject else { return }
            // Re-read the current mode and selection: neither a delayed permission
            // response nor a deselected automatic track may resurrect an old arm.
            reconcileArming()
        }
    }
    private func target(for track: Track, position: Double) -> CaptureTarget {
        let lane = TrackLanes(track: track).recordingLane(start: position, duration: 0.01, clips: track.clips)
        var target = CaptureTarget(track: track.id, input: track.inputPatch ?? defaultInputPatch, format: MediaProcessingFormat.load("record").recordingKey(for: track), name: recordingNames.allocate(track: track.name, clips: track.clips), lane: lane, recordedChannels: track.recordingChannels ?? 2)
        target.postFader = track.recordingPostFader != false
        target.postFX = track.recordingPostFX != false
        target.gain = Float(track.volume)
        target.effects = track.fx
        #if os(macOS)
        if target.postFX, var fx = target.effects {
            let chain = (projectAudio ?? StemAudioPlayback.shared).effects(for: track.id)
            for index in (fx.externalPlugins ?? []).indices {
                let id = fx.externalPlugins![index].id
                if let node = chain?.externalNode(id), let state = JarasVST3.state(node, identifier: id) {
                    fx.externalPlugins![index].componentState = state["componentState"] as? String
                    fx.externalPlugins![index].controllerState = state["controllerState"] as? String
                }
            }
            target.effects = fx
        }
        #endif
        let clip = AudioClip(id: target.id, name: target.name, startTime: position, duration: 0.01, recordingLane: lane)
        RecordingLaneLayout.shared.reserve(track: track, clip: clip)
        LiveRecordingPreview.shared.takes[target.id] = RecordingPreviewTake(start: position, duration: 0.01, channels: Array(repeating: [0], count: target.channelCount))
        return target
    }
    private func updateArmedTargets() {
        guard recording, let show else { return }
        let allTracks = show.current?.tracks.filter { $0.kind == .standard && armed.contains($0.id) } ?? []
        let position = show.snapshot.transport.position
        updateMIDITargets(allTracks.filter { $0.recordingMode == .midi }, position: position)
        let tracks = allTracks.filter { $0.recordingMode != .midi }
        guard let writer else {
            guard !tracks.isEmpty, !busy else { return }
            busy = true
            Task {
                do { try await startAudioCapture(tracks: tracks) }
                catch { self.error = error.localizedDescription }
                busy = false; reconcileArming()
            }
            return
        }
        let kept = Set(tracks.map(\.id))
        let removedIDs = Set(activeTargets.filter { !kept.contains($0.key) }.map { $0.value.id })
        for (id, target) in activeTargets where !kept.contains(id) { pendingTakes.insert(target.id); activeTargets[id] = nil }
        for track in tracks where activeTargets[track.id] == nil { activeTargets[track.id] = target(for: track, position: position) }
        let recordedProject = project
        writer.changeTargets(Array(activeTargets.values), position: position) { [weak self] items, message in
            Task { @MainActor [weak self] in
                self?.accept(items, message: message, project: recordedProject)
                for id in removedIDs { RecordingLaneLayout.shared.remove(id); LiveRecordingPreview.shared.takes[id] = nil; self?.pendingTakes.remove(id) }
            }
        }
    }
    private func updateMIDITargets(_ tracks: [Track], position: Double) {
        let kept = Set(tracks.map(\.id))
        for id in Array(midiTakes.keys) where !kept.contains(id) { finishMIDITake(id, at: position) }
        guard let song = show?.current else { return }
        for track in tracks where midiTakes[track.id] == nil {
            let lane = TrackLanes(track: track).recordingLane(start: position, duration: 0.01, clips: track.clips)
            let take = MIDIRecordingTake(track: track.id, song: song, startTime: position, lane: lane, name: recordingNames.allocate(track: track.name, clips: track.clips))
            midiTakes[track.id] = take
            RecordingLaneLayout.shared.reserve(track: track, clip: AudioClip(id: take.id, name: take.name, startTime: position, duration: 0.01, recordingLane: lane, midi: MIDIItem(sourceBPM: take.sourceBPM)))
            LiveRecordingPreview.shared.takes[take.id] = RecordingPreviewTake(start: position, duration: 0.01, channels: [])
        }
    }
    private func finishMIDITake(_ track: UUID, at position: Double) {
        guard var take = midiTakes.removeValue(forKey: track) else { return }
        if let clip = take.finish(at: position), show?.snapshot.project.id == project { addRecordedClip(clip, track: track) }
        RecordingLaneLayout.shared.remove(take.id); LiveRecordingPreview.shared.takes[take.id] = nil
    }
    private func receiveMIDI(device: Int32, status: UInt8, number: UInt8, value: UInt8, timestamp: Double) {
        guard recording, timestamp >= midiStartTime, let show else { return }
        let position = startPosition + timestamp - midiStartTime
        let slots = AudioDeviceSettings.shared.midiSlots
        for track in show.current?.tracks ?? [] {
            guard midiTakes[track.id] != nil, track.acceptsMIDI(status: status), let slot = track.midiInput,
                  slots.indices.contains(slot - 1), slots[slot - 1] == device else { continue }
            midiTakes[track.id]?.receive(source: device, status: status, number: number, value: value, position: position)
        }
    }
    private func addRecordedClip(_ clip: AudioClip, track id: UUID) {
        guard let show, let track = show.current?.tracks.first(where: { $0.id == id }) else { return }
        var clip = clip
        clip.recordingLane = TrackLanes(track: track).recordingLane(start: clip.startTime, duration: clip.duration, clips: track.clips)
        show.addRecordedClip(clip, track: id)
    }
    private func accept(_ items: [CapturedItem], message: String?, project recordedProject: UUID?) {
        if let show, show.snapshot.project.id == recordedProject {
            for item in items {
                addRecordedClip(item.clip, track: item.track)
                RecordingLaneLayout.shared.remove(item.clip.id); LiveRecordingPreview.shared.takes[item.clip.id] = nil
                pendingTakes.remove(item.clip.id)
                if !show.snapshot.project.songs.flatMap(\.tracks).flatMap(\.clips).contains(where: { $0.id == item.clip.id }) { error = show.message }
            }
        }
        if let message { error = message }
    }
    func toggle(show: ShowController) {
        if recording {
            finish()
            show.send(.stop)
            return
        }
        guard !busy, show.canControl(), let directory, project == show.snapshot.project.id else { return }
        let tracks = show.current?.tracks.filter { $0.kind == .standard && armed.contains($0.id) } ?? []
        #if os(iOS)
        guard !tracks.isEmpty, tracks.allSatisfy({ $0.recordingMode != .midi }) else {
            error = JarasLocalization.string("Arm an audio track before recording."); return
        }
        #endif
        let audioTracks = tracks.filter { $0.recordingMode != .midi }
        if !audioTracks.isEmpty, !AudioDestinationSpace.confirm(at: directory.appendingPathComponent("Stems", isDirectory: true)) { return }
        busy = true; self.show = show; error = ""; previewSession = UUID()
        Task {
            do {
                if !audioTracks.isEmpty { try await startAudioCapture(tracks: audioTracks) }
                guard self.project == show.snapshot.project.id, show.canControl() else { busy = false; return }
                startPosition = show.snapshot.transport.playing ? show.snapshot.transport.position : show.snapshot.transport.editPosition ?? show.snapshot.transport.position
                midiStartTime = ProcessInfo.processInfo.systemUptime
                recordingSong = show.snapshot.transport.songId
                lastPosition = startPosition; lastTime = midiStartTime
                updateMIDITargets(tracks.filter { $0.recordingMode == .midi }, position: startPosition)
                recording = true; busy = false; reconcileArming()
                if !show.snapshot.transport.playing { show.send(.play) }
            } catch {
                busy = false; activeTargets = [:]; midiTakes = [:]
                LiveRecordingPreview.shared.takes = [:]; RecordingLaneLayout.shared.clear()
                self.error = error.localizedDescription
            }
        }
    }
    private func startAudioCapture(tracks: [Track]) async throws {
        guard let show, let directory, !tracks.isEmpty else { return }
        let requestedProject = project, wasRecording = recording
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        let allowed = permission == .authorized ? true : permission == .notDetermined ? await AVCaptureDevice.requestAccess(for: .audio) : false
        guard allowed else { throw ProjectError.invalid("Allow microphone access in System Settings to record audio.") }
        guard inputChannels > 0 else { throw ProjectError.invalid("Choose an audio input device in Settings.") }
        try configureInput(allowCaptureSetup: true)
        let requestedInputUID = AudioDeviceSettings.shared.inputUID
        let requestedInputDevice = configuredInput
        let format = try captureFormat()
        guard format.channelCount > 0 && format.sampleRate > 0 else { throw ProjectError.invalid("No audio input is available.") }
        let position = show.snapshot.transport.playing ? show.snapshot.transport.position : show.snapshot.transport.editPosition ?? show.snapshot.transport.position
        let targets = tracks.map { target(for: $0, position: position) }
        let ring = captureRing ?? JarasCaptureRing(channels: UInt(format.channelCount), capacity: UInt(format.sampleRate * 8))
        ring.endCapture()
        do {
            let writer = try await Task.detached(priority: .userInitiated) { try CaptureWriter(targets: targets, directory: directory, format: format, ring: ring) }.value
            do {
                guard project == requestedProject, project == show.snapshot.project.id, show.canControl(), !wasRecording || recording else {
                    throw ProjectError.invalid("The destination project is no longer available.")
                }
                // Creating files yields to the main actor. The selected input or
                // its format may have changed before the writer is ready.
                try requireConfiguredInput(expectedUID: requestedInputUID, expectedDevice: requestedInputDevice)
                guard format.isEqual(try captureFormat()) else {
                    throw ProjectError.invalid(JarasLocalization.string("The audio input changed while preparing the recording. Start recording again."))
                }
            } catch {
                writer.finish(start: position) { _, _ in }
                throw error
            }
            let actualPosition = show.snapshot.transport.playing ? show.snapshot.transport.position : show.snapshot.transport.editPosition ?? show.snapshot.transport.position
            self.writer = writer
            activeTargets = Dictionary(uniqueKeysWithValues: targets.map { ($0.track, $0) })
            writer.setInitialPosition(actualPosition)
            for target in targets {
                RecordingLaneLayout.shared.update(target.id, start: actualPosition)
                LiveRecordingPreview.shared.takes[target.id]?.start = actualPosition
            }
            let session = previewSession
            writer.takePreview = { [weak self] durations, waveforms in
                Task { @MainActor in
                    guard let self, self.previewSession == session else { return }
                    for (id, duration) in durations {
                        RecordingLaneLayout.shared.update(id, duration: duration)
                        LiveRecordingPreview.shared.takes[id]?.duration = max(0.01, duration)
                        if let waveform = waveforms[id] { LiveRecordingPreview.shared.takes[id]?.waveform = waveform }
                    }
                }
            }
            writer.start()
            if captureRing == nil {
                captureRing = ring
                rebuildInputTap()
            }
            do { try startInputEngine() }
            catch {
                releaseInput(); self.writer = nil; activeTargets = [:]
                writer.finish(start: actualPosition) { _, _ in }
                throw error
            }
        } catch {
            for target in targets {
                RecordingLaneLayout.shared.remove(target.id); LiveRecordingPreview.shared.takes[target.id] = nil
            }
            throw error
        }
    }
    private var recordingGains: [UUID: Float] = [:]
    func observe(_ snapshot: ShowSnapshot) {
        // Playback samples carry no arming changes. With no configured REC
        // tracks or capture resources, there is nothing to reconcile or stop.
        // Automatic REC still takes the normal path while it is deselected.
        if !recording, !busy, !armState.hasConfiguredTracks, armed.isEmpty,
           captureRing == nil, monitorConfig.isEmpty, !tapInstalled, !inputEngineRunning {
            if !(projectAudio ?? StemAudioPlayback.shared).armedMIDIRecordingTracks.isEmpty {
                (projectAudio ?? StemAudioPlayback.shared).armedMIDIRecordingTracks = []
            }
            return
        }
        let validTracks = Set(snapshot.project.songs.flatMap(\.tracks).filter { $0.kind == .standard }.map(\.id))
        var retained = armState; retained.retain(validTracks)
        if retained != armState { armState = retained; microphoneTracks.formIntersection(validTracks); reconcileArming() }
        guard recording else { reconcileArming(); releaseInputIfIdle(); return }
        guard snapshot.transport.songId == recordingSong else { finish(); return }
        guard snapshot.transport.playing else { finish(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if abs(snapshot.transport.position - lastPosition - (now - lastTime)) > 0.2 {
            finish(); error = "Recording stopped at the timeline jump. The take has been preserved."
        }
        lastTime = now; lastPosition = snapshot.transport.position
        guard recording else { return }
        if let song = snapshot.project.songs.first(where: { $0.id == recordingSong }) {
            let gains = Dictionary(uniqueKeysWithValues: song.tracks.filter { activeTargets[$0.id] != nil }.map { ($0.id, Float($0.volume)) })
            if gains != recordingGains { recordingGains = gains; writer?.updateGains(gains) }
        }
        for take in midiTakes.values {
            let duration = max(0.01, snapshot.transport.position - take.startTime)
            RecordingLaneLayout.shared.update(take.id, duration: duration)
            LiveRecordingPreview.shared.takes[take.id]?.duration = duration
        }
    }
    func finishAndWait() async {
        while busy {
            do { try await Task.sleep(nanoseconds: 20_000_000) }
            catch { return }
        }
        guard !Task.isCancelled else { return }
        finish()
        while busy {
            do { try await Task.sleep(nanoseconds: 20_000_000) }
            catch { return }
        }
    }
    func finish() {
        guard recording else { return }
        let end = lastPosition + max(0, ProcessInfo.processInfo.systemUptime - lastTime)
        recording = false; busy = true
        for track in Array(midiTakes.keys) { finishMIDITake(track, at: end) }
        guard let writer else { finishCleanup(); return }
        // Stop writing PCM, not the audio device shared with live playback.
        writer.ring.endCapture(); self.writer = nil
        let recordedProject = project
        writer.finish(start: startPosition) { [weak self] items, message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.accept(items, message: message, project: recordedProject)
                self.finishCleanup()
                if let message { self.error = message }
            }
        }
    }
    private func finishCleanup() {
        activeTargets = [:]; pendingTakes = []
        previewSession = UUID(); LiveRecordingPreview.shared.takes = [:]; RecordingLaneLayout.shared.clear()
        busy = false; reconcileArming(); releaseInputIfIdle()
    }
    private func releaseInputIfIdle() {
        guard !recording, !busy, monitorConfig.isEmpty else { return }
        releaseInput()
    }
    private func releaseInput() {
        #if os(iOS)
        if AudioDeviceSettings.shared.localSessionReconfiguring {
            // A route callback cannot synchronously stop another RemoteIO
            // engine either. Preserve the tap/rings until its stop finishes.
            captureRing?.endCapture()
            if mobileCaptureStop == nil, captureRing != nil || tapInstalled || !monitorConfig.isEmpty {
                let hardware = mobileInput
                mobileCaptureStop = MobileAudioHardwareStop { hardware.stop() }
            }
            return
        }
        #endif
        guard captureRing != nil || tapInstalled || !monitorConfig.isEmpty || inputEngineRunning else { return }
        #if os(iOS)
        mobileInput.stop()
        #else
        captureEngine.stop()
        #endif
        finishInputRelease()
    }
    private func finishInputRelease() {
        for config in monitorConfig { (projectAudio ?? StemAudioPlayback.shared).setInputMonitor(config.track, source: nil) }
        monitorConfig = []; monitorRings = []
        captureRing?.endCapture()
        #if os(iOS)
        mobileInput.setCapture(nil); tapInstalled = false
        #else
        if tapInstalled { captureEngine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        #endif
        captureRing = nil
    }
}

struct TrackRecordButton: View {
    let show: ShowController
    let track: Track
    @ObservedObject private var recorder = TrackRecording.shared
    @State private var editingMode = false
    var body: some View {
        Button {
            let targets = show.mixerControlTargets(track.id).filter { $0.kind == .standard }
            let requiresInput = targets.contains { $0.recordingMode != .midi && $0.fx?.instrumentKeys.isEmpty != false && !($0.fx?.externalPlugins?.contains { $0.category.contains("Instrument") } ?? false) }
            recorder.setMode(recorder.armState.mode(for: track.id).next, tracks: Set(targets.map(\.id)), requiresAudioInput: requiresInput)
        } label: {
            Group {
                if recorder.armState.mode(for: track.id) == .automatic {
                    Text(verbatim: "A").font(.jarasSystem(size: 11, weight: .bold))
                } else { Image(systemName: "record.circle") }
            }
                .frame(width: 22, height: 21)
        }.buttonStyle(RecordingButtonStyle(active: recorder.armed.contains(track.id)))
        #if os(macOS)
        .background(TrackControlSelectionExclusion())
        #endif
        .immediateRightClick { editingMode = true }
        .popover(isPresented: $editingMode) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recording mode").font(.jarasHeadline)
                Picker("Recording mode", selection: Binding(get: { track.recordingChannels ?? 2 }, set: { show.setRecordingChannels(track.id, channel: $0) })) {
                    Text("Mono").tag(1)
                    Text("Stereo").tag(2)
                    #if os(macOS)
                    Text("MIDI").tag(0)
                    #endif
                }.pickerStyle(.segmented).labelsHidden().disabled(recorder.recording || recorder.busy)
                if track.recordingMode != .midi {
                    Picker("Format", selection: Binding(get: { track.recordingFormat ?? "" }, set: {
                        show.setRecordingFormat(track.id, format: $0.isEmpty ? nil : $0)
                    })) {
                        Text(verbatim: "Default - " + MediaProcessingFormat.load("record").recordingDisplayName).tag("")
                        Text(verbatim: "WAV · 24-bit PCM").tag("wav")
                        Text(verbatim: "WAV · 32-bit float").tag("wav32")
                        Text(verbatim: "MP3 · \(MediaProcessingFormat.load("record").bitrate) kbps").tag("mp3")
                    }.disabled(recorder.recording || recorder.busy)
                    Picker("Recording level", selection: Binding(get: { track.recordingPostFader != false }, set: { show.setRecordingStage(track.id, postFader: $0) })) {
                        Text("Pre-fader").tag(false)
                        Text("Post-fader").tag(true)
                    }.pickerStyle(.segmented).disabled(recorder.recording || recorder.busy)
                    Picker("Recording effects", selection: Binding(get: { track.recordingPostFX != false }, set: { show.setRecordingStage(track.id, postFX: $0) })) {
                        Text("Pre-FX").tag(false)
                        Text("Post-FX").tag(true)
                    }.pickerStyle(.segmented).disabled(recorder.recording || recorder.busy)
                    Picker("Input monitoring", selection: Binding(get: { track.inputMonitoring != false }, set: { show.setInputMonitoring(track.id, enabled: $0) })) {
                        Text(verbatim: "Monitor On").tag(true)
                        Text(verbatim: "Monitor Off").tag(false)
                    }.pickerStyle(.segmented).labelsHidden()
                }
            }.padding(16)
        }
        .accessibilityLabel("Arm track for recording")
        .accessibilityValue(Text(recorder.armState.mode(for: track.id) == .automatic ? "Automatic record arm" : recorder.armed.contains(track.id) ? "Armed" : "Off"))
        .jarasHelp("Record arm: Off → Armed → Automatic (selected track)")

    }
}
/// Armed and recording controls remain solid red throughout recording.
private struct RecordingButtonStyle: ButtonStyle {
    let active: Bool
    var width: CGFloat = 22
    var height: CGFloat = 21
    var fontSize: CGFloat = 10
    var cornerRadius: CGFloat = 3
    var transport = false
    private let red = Color(red: 1, green: 0.12, blue: 0.12)
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.jarasSystem(size: fontSize, weight: .semibold))
            .lineLimit(1).minimumScaleFactor(0.75)
            .frame(width: width, height: height)
            .foregroundStyle(transport ? Color.white : active ? Color.black : Color.red)
            .background(transport ? (active ? JarasTheme.transportRed : JarasTheme.liveOffRed).opacity(configuration.isPressed ? 0.85 : 1) :
                active ? red.opacity(configuration.isPressed ? 0.75 : 1) :
                JarasTheme.text.opacity(configuration.isPressed ? 0.24 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(transport ? (active ? JarasTheme.transportRed : Color.white.opacity(0.45)) : .clear))
            .contentShape(Rectangle())
            .transaction { $0.animation = nil }
    }
}

struct TransportRecordButton: View {
    @Environment(\.transportControlWidth) private var buttonWidth
    let show: ShowController
    @ObservedObject private var recorder = TrackRecording.shared
    var body: some View {
        Button { recorder.toggle(show: show) } label: {
            Label("REC", systemImage: recorder.recording ? "stop.circle.fill" : "record.circle")
        }.buttonStyle(RecordingButtonStyle(active: recorder.recording, width: buttonWidth,
            height: TransportControlMetrics.height, fontSize: TransportControlMetrics.font, cornerRadius: 6, transport: true))
            .disabled(recorder.busy).jarasHelp("Record armed tracks").accessibilityLabel("Record")
    }
}
