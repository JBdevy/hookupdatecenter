#if os(macOS)
import SwiftUI
import AppKit
import AVFoundation
import Combine

struct CatStemRequest {
    let project: Project
    let song: Song
    let track: Track
    let clip: AudioClip
    let directory: URL
}

private enum CatStemRenderer {
    static func interpreter(in runtime: URL) -> URL {
        #if arch(arm64)
        return runtime.appendingPathComponent("arm64/python/bin/python3.11")
        #else
        return runtime.appendingPathComponent("x86_64/python/bin/python3.11")
        #endif
    }
    static func run(_ request: CatStemRequest, runtime: URL, worker: URL,
                    cancellation: AudioExportCancellation,
                    progress: @escaping @Sendable (Double, String) -> Void) throws -> (URL, [Track]) {
        let fm = FileManager.default
        let folder = request.directory.appendingPathComponent("Stems/CatStem-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? fm.removeItem(at: folder) } }
        func checkCancellation() throws { if cancellation.cancelled { throw CancellationError() } }
        try checkCancellation()
        progress(0, "Preparando o áudio…")
        var source = request.song
        var time = source.projectTime; time.timebase = .free; source.timeSettings = time
        source.markers?.removeAll { $0.isTempo }
        for index in source.parts.indices { source.parts[index].pitchSemitones = 0 }
        for index in source.tracks.indices {
            source.tracks[index].fx = nil; source.tracks[index].volume = 1; source.tracks[index].pan = 0
            source.tracks[index].mute = false; source.tracks[index].solo = false
            for item in source.tracks[index].clips.indices { source.tracks[index].clips[item].muted = false }
        }
        let job = AudioExportJob(id: request.clip.id.uuidString, fileName: "input.wav", start: request.clip.startTime,
                                 end: request.clip.startTime + request.clip.duration, track: request.track.id, clip: request.clip.id)
        try OfflineAudioExport.run(project: request.project, song: source, plan: AudioExportPlan(jobs: [job]),
                                   mediaDirectory: request.directory, outputDirectory: folder, sampleRate: 44100,
                                   encoding: AudioExportEncoding(format: .wav, bitDepth: 32, sampleRate: 44100), cancellation: cancellation) {
            progress($0.fraction * 0.08, "Preparando o áudio…")
        }
        try checkCancellation()
        let log = folder.appendingPathComponent("worker.log")
        fm.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = CatStemRenderer.interpreter(in: runtime)
        process.arguments = ["-I", worker.path, "--input", folder.appendingPathComponent("input.wav").path,
                             "--output", folder.path, "--model", runtime.appendingPathComponent("5c90dfd2-34c22ccb.th").path]
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("PYTHON") { environment.removeValue(forKey: key) }
        environment["PYTHONNOUSERSITE"] = "1"; environment["OMP_NUM_THREADS"] = "4"
        environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        process.environment = environment
        process.standardOutput = output; process.standardError = output
        try process.run()
        var lastProgress = Data()
        var cancelTime: Date?
        while process.isRunning {
            if cancellation.cancelled {
                if cancelTime == nil { cancelTime = Date(); process.terminate() }
                else if Date().timeIntervalSince(cancelTime!) > 2 { kill(process.processIdentifier, SIGKILL) }
            }
            if let data = try? Data(contentsOf: folder.appendingPathComponent("progress.json")), data != lastProgress,
               let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let fraction = event["fraction"] as? Double, let message = event["message"] as? String {
                lastProgress = data; progress(0.08 + min(1, max(0, fraction)) * 0.82, message)
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        process.waitUntilExit()
        try checkCancellation()
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: folder.appendingPathComponent("error.txt"), encoding: .utf8)) ?? "O motor de separação encerrou inesperadamente."
            throw ProjectError.invalid(String(detail.prefix(600)))
        }
        var tracks: [Track] = []
        for (index, stem) in CatStem.allCases.enumerated() {
            try checkCancellation()
            progress(0.9 + Double(index) * 0.02, "Preparando \(stem.rawValue)…")
            let url = folder.appendingPathComponent(stem.rawValue + ".wav")
            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.channelCount == 2, file.processingFormat.sampleRate == 44100,
                  abs(Double(file.length) / 44100 - request.clip.duration) < 0.01 else {
                throw ProjectError.invalid("O áudio separado tem duração ou formato incorreto.")
            }
            let overview = try StemProjectImporter.audioOverview(url, duration: request.clip.duration)
            var clip = AudioClip(id: UUID(), name: request.clip.name + " · " + stem.rawValue,
                                 startTime: request.clip.startTime, duration: request.clip.duration,
                                 waveform: overview.waveform, audioFile: AudioFile(path: "Stems/" + folder.lastPathComponent + "/" + url.lastPathComponent))
            clip.waveformChannels = overview.channels
            var track = Track(id: UUID(), name: stem.rawValue + " · " + request.clip.name, role: stem.role, color: stem.color)
            track.clips = [clip]; track.parentTrackID = request.track.parentTrackID
            track.volume = request.track.volume; track.pan = request.track.pan; track.fx = request.track.fx
            track.mute = request.track.mute; track.solo = request.track.solo
            track.patch = request.track.patch; track.secondaryPatch = request.track.secondaryPatch; track.outputs = request.track.outputs
            track.phaseInverted = request.track.phaseInverted
            tracks.append(track)
        }
        for name in ["input.wav", "worker.log", "progress.json"] { try? fm.removeItem(at: folder.appendingPathComponent(name)) }
        try checkCancellation()
        success = true
        return (folder, tracks)
    }
}

@MainActor final class CatStemSession: ObservableObject {
    @Published var running = false
    @Published var progress = 0.0
    @Published var status = ""
    @Published var error = ""
    private var cancellation = AudioExportCancellation()
    func cancel() { cancellation.cancel(); if running { status = "Cancelando…" } }
    func start(_ request: CatStemRequest, show: ShowController, documents: ProjectDocuments) {
        guard !running, !documents.busy else { return }
        guard let resource = Bundle.main.resourceURL else { return }
        let runtime = resource.appendingPathComponent("StemSeparationRuntime")
        let worker = resource.appendingPathComponent("StemSeparation/separate.py")
        guard FileManager.default.isExecutableFile(atPath: CatStemRenderer.interpreter(in: runtime).path),
              FileManager.default.fileExists(atPath: runtime.appendingPathComponent("5c90dfd2-34c22ccb.th").path) else {
            error = "O motor CatStemSeparation 5 não está incluído nesta instalação."; return
        }
        guard AudioDestinationSpace.confirm(at: request.directory.appendingPathComponent("Stems")) else { return }
        running = true; documents.busy = true; error = ""; progress = 0
        cancellation = AudioExportCancellation()
        let token = cancellation
        Task {
            defer { running = false; documents.busy = false }
            do {
                let (folder, tracks) = try await Task.detached(priority: .utility) {
                    try CatStemRenderer.run(request, runtime: runtime, worker: worker, cancellation: token) { fraction, text in
                        Task { @MainActor [weak self] in
                            guard let self, self.running, !token.cancelled else { return }
                            self.progress = fraction; self.status = text
                        }
                    }
                }.value
                do {
                    if token.cancelled { throw CancellationError() }
                    try show.insertSeparatedStems(tracks, song: request.song.id, sourceTrack: request.track.id,
                                                  original: request.clip, project: request.project.id)
                } catch { try? FileManager.default.removeItem(at: folder); throw error }
                progress = 1; status = "Pronto — o original foi preservado e silenciado."
            } catch is CancellationError { status = "Separação cancelada." }
            catch {
                if token.cancelled { status = "Separação cancelada." }
                else { self.error = error.localizedDescription; status = "" }
            }
        }
    }
}

/// The processor belongs to the track/item FX chain, independent of this window.
/// Closing the editor never stops the worker or removes the saved stem mix.
struct CatStemFXEditor: View {
    let show: ShowController
    let track: UUID?
    var clip: UUID? = nil
    @State private var settings = NativeFXSettings()
    @State private var project: UUID?
    @State private var status = ""
    @State private var failed = false
    @State private var available = false
    @State private var changed = false
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private var current: NativeFXSettings { clip.map { show.clipFXSettings($0) } ?? show.fxSettings(track) }
    private var title: String {
        if let clip { return FXModelLookup.clip(clip, in: show.snapshot.project)?.name ?? "—" }
        return track.flatMap { FXModelLookup.track($0, in: show.snapshot.project)?.name } ?? "Master"
    }
    private func refreshStatus() {
        guard available else { return }
        guard settings.isEnabled(NativeFXSettings.stemSeparator) else { status = "Bypass"; failed = false; return }
        guard let report = StemAudioPlayback.shared.effects(for: clip ?? track)?.stemSeparatorStatus else {
            status = "Preparando CatStem…"; failed = false; return
        }
        let state = report["state"] as? String ?? "loading"
        failed = state == "error" || state == "fault" || state == "unavailable"
        if failed { status = report["error"] as? String ?? "Não foi possível iniciar o processamento." }
        else if state == "ready" || state == "running" { status = "Tempo real · 5 stems" }
        else { status = "Preparando CatStem…" }
    }
    private func update(_ value: NativeFXSettings, commit: Bool) {
        guard project == show.snapshot.project.id else { return }
        settings = value
        if let clip { show.updateClipFX(clip, effect: NativeFXSettings.stemSeparator, settings: value) }
        else { show.updateFX(track, effect: NativeFXSettings.stemSeparator, settings: value) }
        changed = true
        if commit { show.commitFX(); changed = false }
        refreshStatus()
    }
    private func source(_ index: Int) -> Binding<NativeStemMix.Source> {
        Binding(get: { settings.stemParameters.sources[index] }, set: { value in
            var next = current
            next.stemParameters.sources[index] = value
            update(next, commit: false)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform").font(.title2).foregroundStyle(JarasTheme.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "CatStemSeparation 5").font(.system(size: 19, weight: .semibold))
                    Text(verbatim: title).font(.caption).foregroundStyle(JarasTheme.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { settings.isEnabled(NativeFXSettings.stemSeparator) }, set: { enabled in
                    var next = current; next.setEnabled(NativeFXSettings.stemSeparator, enabled: enabled)
                    update(next, commit: true)
                })).toggleStyle(.switch).labelsHidden().tint(JarasTheme.green).disabled(!available)
            }.padding(.bottom, 4)
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(CatStem.allCases.enumerated()), id: \.element) { index, stem in
                    CatStemRealtimeRow(stem: stem, source: source(index)) {
                        if changed { show.commitFX(); changed = false }
                    }
                }
            }.disabled(!available || !settings.isEnabled(NativeFXSettings.stemSeparator))
            Text(verbatim: status).font(.caption).foregroundStyle(failed ? Color.red : JarasTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 560).background(JarasTheme.background).foregroundStyle(JarasTheme.text)
            .onAppear {
                project = show.snapshot.project.id; settings = current
                do { _ = try CatStemRealtimeRuntime.paths(); available = true; refreshStatus() }
                catch { available = false; failed = true; status = error.localizedDescription }
            }
            .onReceive(timer) { _ in settings = current; refreshStatus() }
            .onDisappear { if changed && project == show.snapshot.project.id { show.commitFX() } }
    }
}

private struct CatStemButtonStyle: ButtonStyle {
    var activeColor: Color?
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 10, weight: .bold)).frame(width: 25, height: 19)
            .foregroundStyle(activeColor == nil ? JarasTheme.text : .black)
            .background(activeColor ?? JarasTheme.line)
            .clipShape(RoundedRectangle(cornerRadius: 3)).opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct CatStemRealtimeRow: View {
    let stem: CatStem
    @Binding var source: NativeStemMix.Source
    let commit: () -> Void
    private var gain: Double { source.gain }
    private var level: Double { gain <= 0 ? 0 : min(1, max(0, (20 * log10(gain) + 60) / 72)) }
    private var tint: Color { Color(red: Double((stem.color >> 16) & 255) / 255, green: Double((stem.color >> 8) & 255) / 255, blue: Double(stem.color & 255) / 255) }
    private var readout: String { gain <= 0 ? "−∞ dB" : String(format: "%+.1f dB", 20 * log10(gain)) }
    private var gainSlider: some View {
        GeometryReader { geometry in
            let travel: CGFloat = max(1, geometry.size.height - 22)
            let position = travel * CGFloat(1 - level)
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.5))
                    .frame(width: 6, height: travel + 12).offset(y: 5)
                RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.75))
                    .frame(width: 6, height: travel * CGFloat(level) + 6).offset(y: position + 11)
                RoundedRectangle(cornerRadius: 4).fill(tint).frame(width: 36, height: 22)
                    .overlay(Rectangle().fill(Color.black.opacity(0.7)).frame(width: 28, height: 2))
                    .offset(y: position)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    let fraction = Double(min(1, max(0, 1 - (event.location.y - 11) / travel)))
                    source.gain = fraction <= 0 ? 0 : min(4, pow(10, (fraction * 72 - 60) / 20))
                }.onEnded { _ in commit() })
                .onTapGesture(count: 2) { source.gain = 1; commit() }
                .accessibilityElement().accessibilityLabel(stem.rawValue)
                .accessibilityValue(readout)
                .accessibilityAdjustableAction { direction in
                    let db = gain <= 0 ? -60 : 20 * log10(gain)
                    source.gain = pow(10, min(12, max(-60, db + (direction == .increment ? 1 : -1))) / 20)
                    commit()
                }
        }.frame(height: 240)
    }
    var body: some View {
        VStack(spacing: 12) {
            Text(verbatim: stem.rawValue).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: 7) {
                Button("M") { source.mute.toggle(); commit() }
                    .buttonStyle(CatStemButtonStyle(activeColor: source.mute ? .red : nil))
                    .accessibilityLabel("Mute " + stem.rawValue)
                Button("S") { source.solo.toggle(); commit() }
                    .buttonStyle(CatStemButtonStyle(activeColor: source.solo ? JarasTheme.yellow : nil))
                    .accessibilityLabel("Solo " + stem.rawValue)
            }
            gainSlider
            Text(verbatim: readout).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(JarasTheme.text).lineLimit(1).minimumScaleFactor(0.8)
        }.padding(.horizontal, 8).padding(.vertical, 14).frame(maxWidth: .infinity)
            .background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
#endif
