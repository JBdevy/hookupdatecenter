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

/// CatStem is hosted inside the track/item FX window. Its worker remains offline
/// and only starts after the user selects a source and presses Separar.
struct CatStemFXEditor: View {
    let show: ShowController
    let track: UUID?
    var clip: UUID? = nil
    var body: some View {
        if let documents = FXWindows.shared.documents {
            CatStemFXSourceEditor(show: show, documents: documents, track: track, clip: clip)
        } else { Text("Abra um projeto para usar CatStemSeparation 5.").padding(20) }
    }
}
private struct CatStemFXSourceEditor: View {
    @ObservedObject var show: ShowController
    @ObservedObject var documents: ProjectDocuments
    let track: UUID?
    let clip: UUID?
    @State private var selected: UUID?
    @StateObject private var session = CatStemSession()
    private var sources: [(track: Track, clip: AudioClip)] {
        (show.current?.tracks ?? []).filter { $0.kind == .standard && (track == nil || $0.id == track) }.flatMap { track in
            track.clips.filter { (clip == nil || $0.id == clip) && ($0.audioFile ?? track.audioFile) != nil }.map { (track, $0) }
        }
    }
    var body: some View {
        VStack(spacing: 8) {
            if clip == nil && !sources.isEmpty {
                Picker("Item de áudio", selection: Binding(get: { selected ?? sources.first?.clip.id }, set: { selected = $0; session.error = ""; session.status = "" })) {
                    ForEach(sources.map(\.clip)) { clip in Text(verbatim: clip.name).tag(Optional(clip.id)) }
                }.disabled(session.running).padding(.horizontal, 20).padding(.top, 12)
            }
            if let song = show.current,
               let source = sources.first(where: { $0.clip.id == (selected ?? clip ?? sources.first?.clip.id) }),
               let directory = documents.currentURL?.deletingLastPathComponent() {
                CatStemEditor(request: .init(project: show.snapshot.project, song: song, track: source.track, clip: source.clip, directory: directory),
                              show: show, documents: documents, session: session)
            } else {
                Text("Esta pista não tem itens de áudio para separar.").foregroundStyle(JarasTheme.secondary).padding(20)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(JarasTheme.background)
            .onDisappear { session.cancel() }
    }
}

private struct CatStemEditor: View {
    let request: CatStemRequest
    @ObservedObject var show: ShowController
    @ObservedObject var documents: ProjectDocuments
    @ObservedObject var session: CatStemSession
    private var source: AudioClip? {
        show.snapshot.project.songs.first { $0.id == request.song.id }?.tracks.first { $0.id == request.track.id }?.clips.first { $0.id == request.clip.id }
    }
    private var tracks: [Track] {
        let all = show.snapshot.project.songs.first { $0.id == request.song.id }?.tracks ?? []
        return (source?.separatedStemTracks ?? []).compactMap { id in all.first { $0.id == id } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform").font(.title2).foregroundStyle(JarasTheme.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "CatStemSeparation 5").font(.system(size: 19, weight: .semibold))
                    Text(verbatim: request.clip.name).font(.caption).foregroundStyle(JarasTheme.secondary).lineLimit(1)
                }
                Spacer()
                Text(verbatim: "5 STEMS").font(.system(size: 10, weight: .bold)).foregroundStyle(JarasTheme.green)
            }.padding(.bottom, 4)
            ForEach(Array(CatStem.allCases.enumerated()), id: \.element) { index, stem in
                CatStemRow(stem: stem, track: tracks.count == 5 ? tracks[index] : nil, show: show)
            }
            if session.running {
                ProgressView(value: session.progress).tint(JarasTheme.green)
                HStack {
                    Text(verbatim: session.status).font(.caption)
                    Spacer()
                    Button("Cancelar") { session.cancel() }.buttonStyle(.bordered)
                }
            } else if tracks.count == 5 {
                Text("Separação pronta. Os controles ajustam as cinco pistas.").font(.caption).foregroundStyle(JarasTheme.secondary)
            } else {
                HStack(alignment: .center) {
                    Text(source?.separatedStemTracks == nil ? "Cria cinco pistas e preserva o original silenciado." : "Uma das pistas separadas foi removida.")
                        .font(.caption).foregroundStyle(JarasTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Separar") { session.start(request, show: show, documents: documents) }
                        .buttonStyle(.borderedProminent).tint(JarasTheme.green).foregroundStyle(.black)
                        .disabled(documents.busy || source == nil || source?.separatedStemTracks != nil || source != request.clip)
                }
            }
            if !session.error.isEmpty { Text(verbatim: session.error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            else if !session.running && tracks.count != 5 && !session.status.isEmpty { Text(verbatim: session.status).font(.caption) }
        }.padding(20).frame(width: 470).background(JarasTheme.background).foregroundStyle(JarasTheme.text)
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

private struct CatStemRow: View {
    let stem: CatStem
    let track: Track?
    @ObservedObject var show: ShowController
    @State private var dragging: Double?
    private var gain: Double { dragging ?? track?.volume ?? 1 }
    private var level: Double { gain <= 0 ? 0 : min(1, max(0, (20 * log10(gain) + 60) / 72)) }
    private var tint: Color { Color(red: Double((stem.color >> 16) & 255) / 255, green: Double((stem.color >> 8) & 255) / 255, blue: Double(stem.color & 255) / 255) }
    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 3) {
                Button("M") { if let track { show.sendMixerControl(.mute, target: track.id) } }
                    .buttonStyle(CatStemButtonStyle(activeColor: track?.mute == true ? .red : nil))
                    .accessibilityLabel("Mute " + stem.rawValue)
                Button("S") { if let track { show.sendMixerControl(.solo, target: track.id) } }
                    .buttonStyle(CatStemButtonStyle(activeColor: track?.solo == true ? JarasTheme.yellow : nil))
                    .accessibilityLabel("Solo " + stem.rawValue)
            }.frame(width: 26)
            VStack(spacing: 5) {
                HStack {
                    Text(verbatim: stem.rawValue).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                    Spacer()
                    Text(verbatim: gain <= 0 ? "−∞ dB" : String(format: "%+.1f dB", 20 * log10(gain))).font(.system(size: 10, design: .monospaced)).foregroundStyle(JarasTheme.secondary)
                }
                GeometryReader { geometry in
                    let width = max(1, geometry.size.width - 12)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(JarasTheme.line).frame(height: 4)
                        RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.7)).frame(width: width * level + 6, height: 4)
                        Rectangle().fill(tint).frame(width: 12, height: 20).overlay(Rectangle().fill(Color.black.opacity(0.55)).frame(width: 2, height: 12))
                            .offset(x: width * level)
                    }.frame(height: 22).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                            guard let track else { return }
                            let fraction = min(1, max(0, (event.location.x - 6) / width))
                            let value = fraction <= 0 ? 0 : pow(10, (fraction * 72 - 60) / 20)
                            dragging = value; show.previewTrackVolume(track.id, gain: value)
                        }.onEnded { _ in
                            if let track, let dragging { show.sendMixerControl(.volume, target: track.id, value: dragging) }
                            dragging = nil
                        })
                        .onTapGesture(count: 2) { if let track { show.sendMixerControl(.volume, target: track.id, value: 1) } }
                }.frame(height: 22)
            }
        }.padding(.horizontal, 12).padding(.vertical, 8)
            .background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 7))
            .disabled(track == nil).opacity(track == nil ? 0.6 : 1)
    }
}
#endif
