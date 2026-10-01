import SwiftUI
import AVFoundation
#if os(macOS)
import CoreAudio
import AudioToolbox
#endif

private struct CaptureTarget: Sendable {
    let track: UUID
    let input: OutputPatch
    let format: String
    var id = UUID()
    var lane = 0
    var recordedChannels: Int? = nil
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
    var takePreview: (@Sendable ([UUID: Double], [UUID: [[Double]]]) -> Void)?
    private final class Take {
        let target: CaptureTarget
        let url: URL
        var file: AVAudioFile?
        let buffer: AVAudioPCMBuffer
        var overview: RecordingOverview
        var frames: Int64 = 0
        var position: Double?
        init(target: CaptureTarget,url: URL,file: AVAudioFile,buffer: AVAudioPCMBuffer) {
            self.target=target; self.url=url; self.file=file; self.buffer=buffer
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
        let folder = directory.appendingPathComponent("Steams/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard target.input.firstChannel >= 1, target.input.firstChannel + target.input.channelCount - 1 <= channels else { throw ProjectError.invalid("Selected recording input is unavailable.") }
            let aiff = target.format.hasPrefix("aiff")
            let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(aiff ? "aiff" : "wav")
            let settings: [String: Any] = [AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:sampleRate, AVNumberOfChannelsKey:target.channelCount, AVLinearPCMBitDepthKey:target.format.hasSuffix("16pcm") ? 16 : (target.format == "wav32" || target.format.hasSuffix("32pcm")) ? 32 : 24, AVLinearPCMIsFloatKey:target.format == "wav32", AVLinearPCMIsBigEndianKey:aiff, AVLinearPCMIsNonInterleaved:false]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { throw ProjectError.invalid("Could not allocate recording buffer") }
        return Take(target: target, url: url, file: file, buffer: buffer)
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
                if time-lastPreview >= 0.08 { lastPreview=time; takePreview?(Dictionary(uniqueKeysWithValues: takes.map { ($0.target.id, Double($0.frames)/sampleRate) }), Dictionary(uniqueKeysWithValues: takes.map { ($0.target.id, $0.overview.snapshot) })); preview?(time,Dictionary(uniqueKeysWithValues: takes.map { ($0.target.track,$0.overview.snapshot) })) }
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
                            take.overview.append(sample,channel: channel)
                        }
                        take.overview.endFrame()
                    }
                    try take.file?.write(from: take.buffer)
                    take.frames += Int64(count)
                }
                frames += Int64(count)
            } catch { failure = error }
        }
    }
    private func finalize(_ completed: [Take], fallbackStart: Double, completion: @escaping @Sendable ([CapturedItem], String?) -> Void) {
        guard !completed.isEmpty else { return }
        for take in completed { take.file = nil }
        let failure = self.failure?.localizedDescription
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
                    let clip = AudioClip(id: take.target.id, name: "Recording", startTime: take.position ?? fallbackStart, duration: duration, waveform: overview.waveform,
                        audioFile: AudioFile(path: "Steams/Recordings/" + url.lastPathComponent), waveformChannels: overview.channels, recordingLane: take.target.lane)
                    items.append(CapturedItem(track: take.target.track, clip: clip))
                } catch { message = error.localizedDescription }
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
    static let shared = TrackRecording()
    @Published private(set) var armed: Set<UUID> = []
    @Published private(set) var recording = false
    @Published private(set) var busy = false
    @Published var error = ""
    private let captureEngine = AVAudioEngine()
    private var captureRing: JarasCaptureRing?
    private var configuredInput: UInt32 = 0
    private var directory: URL?
    private var project: UUID?
    private var writer: CaptureWriter?
    private var activeTargets: [UUID: CaptureTarget] = [:]
    private var pendingTakes = Set<UUID>()
    private weak var show: ShowController?
    private var startPosition = 0.0
    private var previewSession = UUID()
    private var lastPosition = 0.0
    private var lastTime = 0.0
    var defaultInputPatch: OutputPatch { OutputPatch(firstChannel: 1, channelCount: min(2, max(1, inputChannels))) }
    var inputChannels: Int { configureInput(); return Int(captureEngine.inputNode.outputFormat(forBus: 0).channelCount) }
    private func configureInput() {
        guard !recording && !busy else { return }
        #if os(macOS)
        let audio = AudioDeviceSettings.shared
        var selected = audio.devices.first { $0.id == audio.selectedUID }?.hardwareID ?? 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,mScope: kAudioDevicePropertyScopeInput,mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        if selected == 0 || AudioObjectGetPropertyDataSize(selected,&address,0,nil,&size) != noErr || size == 0 {
            address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,mScope: kAudioObjectPropertyScopeGlobal,mElement: kAudioObjectPropertyElementMain)
            size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&selected) == noErr else { return }
        }
        guard selected != 0, selected != configuredInput, let unit = captureEngine.inputNode.audioUnit else { return }
        releaseInput()
        if AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&selected,UInt32(MemoryLayout<UInt32>.size)) == noErr { configuredInput = selected }
        #endif
    }
    func open(directory: URL, project: UUID) {
        if recording { finish() }
        releaseInput()
        self.directory = directory; self.project = project; armed.removeAll(); LiveRecordingPreview.shared.takes = [:]; RecordingLaneLayout.shared.clear()
    }
    func toggleArm(_ track: UUID, requiresAudioInput: Bool = true) {
        setArmed([track], active: !armed.contains(track), requiresAudioInput: requiresAudioInput)
    }
    func setArmed(_ tracks: Set<UUID>, active: Bool, requiresAudioInput: Bool) {
        guard !busy else { return }
        if !active { armed.subtract(tracks); updateArmedTargets(); return }
        if !requiresAudioInput { armed.formUnion(tracks); updateArmedTargets(); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            armed.formUnion(tracks); updateArmedTargets()
        case .notDetermined:
            let requestedProject = project
            Task {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard project == requestedProject else { return }
                if allowed { armed.formUnion(tracks); updateArmedTargets() }
                else { error = "Allow microphone access in System Settings to record audio." }
            }
        default:
            error = "Allow microphone access in System Settings to record audio."
        }
    }
    private func target(for track: Track, position: Double) -> CaptureTarget {
        let occupied = RecordingLaneLayout.shared.items.values.filter { $0.track == track.id }.map { $0.clip.recordingLane ?? 0 }
        let lane = max(track.clips.isEmpty ? 0 : TrackLanes(track: track).count, (occupied.max().map { $0 + 1 }) ?? 0)
        let target = CaptureTarget(track: track.id, input: track.inputPatch ?? defaultInputPatch, format: MediaProcessingFormat.load("record").recordingKey, lane: lane, recordedChannels: track.recordingChannels ?? 2)
        let clip = AudioClip(id: target.id, name: "Recording", startTime: position, duration: 0.01, recordingLane: lane)
        RecordingLaneLayout.shared.reserve(track: track.id, clip: clip)
        LiveRecordingPreview.shared.takes[target.id] = RecordingPreviewTake(start: position, duration: 0.01, channels: Array(repeating: [0], count: target.channelCount))
        return target
    }
    private func updateArmedTargets() {
        guard recording, let writer, let show else { return }
        let tracks = show.snapshot.project.songs.flatMap(\.tracks).filter { $0.kind == .standard && armed.contains($0.id) }
        let position = show.snapshot.transport.position
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
    private func accept(_ items: [CapturedItem], message: String?, project recordedProject: UUID?) {
        if let show, show.snapshot.project.id == recordedProject {
            for item in items {
                show.addRecordedClip(item.clip, track: item.track)
                RecordingLaneLayout.shared.remove(item.clip.id); LiveRecordingPreview.shared.takes[item.clip.id] = nil
                pendingTakes.remove(item.clip.id)
                if !show.snapshot.project.songs.flatMap(\.tracks).flatMap(\.clips).contains(where: { $0.id == item.clip.id }) { error = show.message }
            }
        }
        if let message { error = message }
    }
    func toggle(show: ShowController) {
        if recording { finish(); return }
        guard !busy, show.canExecute(), let directory, project == show.snapshot.project.id else { return }
        let tracks = show.snapshot.project.songs.flatMap(\.tracks).filter { $0.kind == .standard && armed.contains($0.id) }
        guard AudioDestinationSpace.confirm(at: directory.appendingPathComponent("Steams/Recordings", isDirectory: true)) else { return }
        configureInput()
        let input = captureEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 && format.sampleRate > 0 else { error = "No audio input is available."; return }
        busy = true; self.show = show; error = ""
        startPosition = show.snapshot.transport.playing ? show.snapshot.transport.position : show.snapshot.transport.editPosition ?? show.snapshot.transport.position
        let targets = tracks.map { target(for: $0, position: startPosition) }
        activeTargets = Dictionary(uniqueKeysWithValues: targets.map { ($0.track, $0) })
        let ring = captureRing ?? JarasCaptureRing(channels: UInt(format.channelCount), capacity: UInt(format.sampleRate * 8))
        ring.endCapture()
        Task {
            do {
                let permission = AVCaptureDevice.authorizationStatus(for: .audio)
                let allowed = permission == .authorized ? true : permission == .notDetermined ? await AVCaptureDevice.requestAccess(for: .audio) : false
                guard allowed else { throw ProjectError.invalid("Allow microphone access in System Settings to record audio.") }
                let writer = try await Task.detached(priority: .userInitiated) { try CaptureWriter(targets: targets, directory: directory, format: format, ring: ring) }.value
                guard self.project == show.snapshot.project.id else { busy = false; return }
                startPosition = show.snapshot.transport.playing ? show.snapshot.transport.position : show.snapshot.transport.editPosition ?? show.snapshot.transport.position
                let session = UUID(); previewSession = session
                self.writer = writer
                writer.setInitialPosition(startPosition)
                for target in targets {
                    RecordingLaneLayout.shared.move(target.id, start: startPosition)
                    LiveRecordingPreview.shared.takes[target.id]?.start = startPosition
                }
                writer.takePreview = { [weak self] durations, waveforms in
                    Task { @MainActor in
                        guard let self, self.previewSession == session else { return }
                        for (id, duration) in durations {
                            LiveRecordingPreview.shared.takes[id]?.duration = max(0.01, duration)
                            if let channels = waveforms[id] { LiveRecordingPreview.shared.takes[id]?.channels = channels }
                        }
                    }
                }
                writer.start()
                if captureRing == nil {
                    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in ring.push(buffer) }
                    captureRing = ring
                }
                do { if !captureEngine.isRunning { captureEngine.prepare(); try captureEngine.start() } }
                catch {
                    releaseInput(); self.writer = nil
                    previewSession = UUID(); LiveRecordingPreview.shared.takes = [:]; RecordingLaneLayout.shared.clear()
                    writer.finish(start: startPosition) { _, _ in }
                    throw error
                }
                recording = true; busy = false
                lastPosition = startPosition; lastTime = ProcessInfo.processInfo.systemUptime
                if !show.snapshot.transport.playing { show.send(.play) }
            } catch { busy = false; activeTargets = [:]; LiveRecordingPreview.shared.takes = [:]; RecordingLaneLayout.shared.clear(); self.error = error.localizedDescription }
        }
    }
    func observe(_ snapshot: ShowSnapshot) {
        guard recording else { releaseInputIfIdle(); return }
        guard snapshot.transport.playing else { finish(); return }
        let validTracks = Set(snapshot.project.songs.flatMap(\.tracks).map(\.id))
        if !armed.isSubset(of: validTracks) { armed.formIntersection(validTracks); updateArmedTargets() }
        let now = ProcessInfo.processInfo.systemUptime
        if abs(snapshot.transport.position - lastPosition - (now - lastTime)) > 0.2 {
            finish(); error = "Recording stopped at the timeline jump. The take has been preserved."
        }
        lastTime = now; lastPosition = snapshot.transport.position
    }
    func finishAndWait() async {
        while busy { try? await Task.sleep(nanoseconds: 20_000_000) }
        finish()
        while busy { try? await Task.sleep(nanoseconds: 20_000_000) }
    }
    func finish() {
        guard recording, let writer else { return }
        // Stop writing PCM, not the audio device shared with live playback.
        // The installed tap reuses this ring for subsequent takes.
        writer.ring.endCapture()
        recording = false; busy = true; self.writer = nil
        let recordedProject = project
        writer.finish(start: startPosition) { [weak self] items, message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.accept(items, message: message, project: recordedProject)
                self.activeTargets = [:]; self.pendingTakes = []
                self.previewSession = UUID(); LiveRecordingPreview.shared.takes = [:]; RecordingLaneLayout.shared.clear()
                self.busy = false
                self.releaseInputIfIdle()
                if let message { self.error = message }
            }
        }
    }
    private func releaseInputIfIdle() {
        guard !recording, !busy, show?.isPlaying != true else { return }
        releaseInput()
    }
    private func releaseInput() {
        guard let ring = captureRing else { return }
        ring.endCapture()
        captureEngine.stop()
        captureEngine.inputNode.removeTap(onBus: 0)
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
            let requiresInput = targets.contains { $0.fx?.instrumentKeys.isEmpty != false && !($0.fx?.externalPlugins?.contains { $0.category.contains("Instrument") } ?? false) }
            recorder.setArmed(Set(targets.map(\.id)), active: !recorder.armed.contains(track.id), requiresAudioInput: requiresInput)
        } label: {
            Image(systemName: "record.circle")
                .foregroundStyle(recorder.armed.contains(track.id) ? JarasTheme.green : .red)
                .frame(width: 22, height: 21)
                .background {
                    if recorder.armed.contains(track.id) {
                        ArmedRecordingBackground().transition(.identity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        #if os(macOS)
        .background(TrackControlSelectionExclusion())
        #endif
        .immediateRightClick { editingMode = true }
        .popover(isPresented: $editingMode) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recording mode").font(.headline)
                Picker("Recording mode", selection: Binding(get: { track.recordingChannels ?? 2 }, set: { show.setRecordingChannels(track.id, channel: $0) })) {
                    Text("Mono").tag(1)
                    Text("Stereo").tag(2)
                }.pickerStyle(.segmented).labelsHidden()
            }.padding(16)
        }
        .accessibilityLabel("Arm track for recording").jarasHelp("Arm track for recording")

    }
}
private struct ArmedRecordingBackground: View {
    var body: some View { Color.red.modifier(JarasBlink(active: true, interval: 0.6, lowOpacity: 0.72)) }
}

struct TransportRecordButton: View {
    let show: ShowController
    @ObservedObject private var recorder = TrackRecording.shared
    var body: some View {
        Button { recorder.toggle(show: show) } label: {
            Label("REC", systemImage: recorder.recording ? "stop.circle.fill" : "record.circle")
                .foregroundStyle(recorder.recording ? .red : JarasTheme.secondary)
        }.buttonStyle(TransportButtonStyle(color: .red, active: recorder.recording, fontSize: TransportControlMetrics.font, width: TransportControlMetrics.width, height: TransportControlMetrics.height)).disabled(recorder.busy).jarasHelp("Record armed tracks").accessibilityLabel("Record")
    }
}
