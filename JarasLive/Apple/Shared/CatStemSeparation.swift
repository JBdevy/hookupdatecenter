import SwiftUI
import AVFoundation
import Combine
#if os(macOS)
import AppKit
#endif

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
                    progress: @escaping @Sendable (Double, String) -> Void) throws -> ([URL], [Track]) {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("CatStem-" + UUID().uuidString, isDirectory: true)
        let stemDirectory = request.directory.appendingPathComponent("Stems", isDirectory: true)
        try fm.createDirectory(at: stemDirectory, withIntermediateDirectories: true)
        var names = MediaFileNames(directory: stemDirectory)
        var published: [URL] = []
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var success = false
        defer {
            try? fm.removeItem(at: folder)
            if !success { for file in published { try? fm.removeItem(at: file) } }
        }
        func checkCancellation() throws { if cancellation.cancelled { throw CancellationError() } }
        try checkCancellation()
        progress(0, "Preparando o áudio…")
        var source = request.song
        for index in source.parts.indices { source.parts[index].pitchSemitones = 0 }
        for index in source.tracks.indices {
            source.tracks[index].fx = nil; source.tracks[index].volume = 1; source.tracks[index].pan = 0
            source.tracks[index].mute = false; source.tracks[index].solo = false
            source.tracks[index].automation = nil; source.tracks[index].phaseInverted = false
            for item in source.tracks[index].clips.indices {
                source.tracks[index].clips[item].muted = false
                if var fx = source.tracks[index].clips[item].fx {
                    fx.inserted.removeAll { $0 == NativeFXSettings.stemSeparator }
                    fx.stemSeparatorEnabled = false; fx.stemMix = nil; source.tracks[index].clips[item].fx = fx
                }
            }
        }
        let job = AudioExportJob(id: request.clip.id.uuidString, fileName: "input.wav", start: request.clip.startTime,
                                 end: request.clip.startTime + request.clip.duration, track: request.track.id, clip: request.clip.id)
        try OfflineAudioExport.run(project: request.project, song: source, plan: AudioExportPlan(jobs: [job]),
                                   mediaDirectory: request.directory, outputDirectory: folder, sampleRate: 44100,
                                   encoding: AudioExportEncoding(format: .wav, bitDepth: 32, sampleRate: 44100), cancellation: cancellation) {
            progress($0.fraction * 0.08, "Preparando o áudio…")
        }
        try checkCancellation()
        #if os(macOS)
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
        #else
        let separationStarted = ProcessInfo.processInfo.systemUptime
        try JarasStemSeparator.separateAudio(folder.appendingPathComponent("input.wav"),
            outputDirectory: folder, coreMLModel: CatStemRealtimeRuntime.modelURL(),
            cancellation: { cancellation.cancelled }, progress: { fraction in
                var message = "Separando os instrumentos…"
                let elapsed = ProcessInfo.processInfo.systemUptime - separationStarted
                if fraction > 0, fraction < 1, elapsed >= 3 {
                    let remaining = Int(min(604800, max(0, elapsed / fraction * (1 - fraction))).rounded())
                    message += String(format: "\nRestante estimado: %d min %02d s", remaining / 60, remaining % 60)
                }
                progress(0.08 + min(1, max(0, fraction)) * 0.82, message)
            })
        try checkCancellation()
        #endif
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
            let outputName = AudioSeparation.outputName(stem, original: request.clip.name)
            let destination = stemDirectory.appendingPathComponent(names.allocate(outputName + ".wav"))
            try fm.moveItem(at: url, to: destination); published.append(destination)
            var clip = AudioClip(id: UUID(), name: outputName,
                                 startTime: request.clip.startTime, duration: request.clip.duration,
                                 waveform: overview.waveform, audioFile: AudioFile(path: "Stems/" + destination.lastPathComponent))
            clip.waveformChannels = overview.channels; clip.regionOwnerID = request.clip.regionOwnerID
            clip.renderedTempo = true
            var track = Track(id: UUID(), name: outputName, role: stem.role, color: stem.color)
            track.clips = [clip]; track.parentTrackID = request.track.parentTrackID
            track.volume = request.track.volume; track.pan = request.track.pan; track.fx = request.track.fx
            if var fx = track.fx {
                fx.inserted.removeAll { $0 == NativeFXSettings.stemSeparator }
                fx.stemSeparatorEnabled = false; fx.stemMix = nil; track.fx = fx
            }
            track.mute = request.track.mute; track.solo = request.track.solo
            track.patch = request.track.patch; track.secondaryPatch = request.track.secondaryPatch; track.outputs = request.track.outputs
            track.phaseInverted = request.track.phaseInverted
            tracks.append(track)
        }
        for name in ["input.wav", "worker.log", "progress.json"] { try? fm.removeItem(at: folder.appendingPathComponent(name)) }
        try checkCancellation()
        success = true
        return (published, tracks)
    }
}

@MainActor final class CatStemSession: ObservableObject {
    @Published var running = false
    @Published var progress = 0.0
    @Published var status = ""
    @Published var error = ""
    private var cancellation = AudioExportCancellation()
    // Cancellation releases UI admission immediately. The immutable render
    // snapshot can finish cleanup without retaining transport/input ownership.
    private var releaseBusy: (() -> Void)?
    func cancel() {
        cancellation.cancel()
        releaseBusy?(); releaseBusy = nil
        if running { status = "Cancelando…" }
    }
    func start(item: UUID, show: ShowController, documents: ProjectDocuments) {
        guard !running else { return }
        error = ""; status = ""; progress = 0
        guard show.canControl(), !documents.busy else { error = "Conclua a operação atual antes de separar áudio."; return }
        guard let directory = documents.currentURL?.deletingLastPathComponent() else { error = "Salve o projeto antes de separar áudio."; return }
        guard let song = show.current, let track = song.tracks.first(where: { $0.clips.contains { $0.id == item } }),
              track.kind == .standard, let clip = track.clips.first(where: { $0.id == item }),
              AudioSeparation.accepts(clip, on: track) else { error = "Selecione apenas um item de áudio."; return }
        start(CatStemRequest(project: show.snapshot.project, song: song, track: track, clip: clip, directory: directory), show: show, documents: documents)
    }
    func start(_ request: CatStemRequest, show: ShowController, documents: ProjectDocuments) {
        guard !running, !documents.busy else { return }
        guard let resource = Bundle.main.resourceURL else { return }
        let runtime = resource.appendingPathComponent("StemSeparationRuntime")
        let worker = resource.appendingPathComponent("StemSeparation/separate.py")
        #if os(macOS)
        guard FileManager.default.isExecutableFile(atPath: CatStemRenderer.interpreter(in: runtime).path),
              FileManager.default.fileExists(atPath: runtime.appendingPathComponent("5c90dfd2-34c22ccb.th").path) else {
            error = "O motor CatStemSeparation 5 não está incluído nesta instalação."; return
        }
        #else
        do { _ = try CatStemRealtimeRuntime.modelURL() }
        catch { self.error = error.localizedDescription; return }
        #endif
        let required = request.clip.duration * 44100 * 2 * 4 * 6 + 16_777_216
        if let available = AudioDestinationSpace.availableBytes(at: request.directory), Double(available) < required {
            error = String(format: "Espaço insuficiente: a separação precisa de aproximadamente %.2f GB livres.", required / 1_000_000_000); return
        }
        guard AudioDestinationSpace.confirm(at: request.directory.appendingPathComponent("Stems")) else { return }
        running = true; documents.presentsOwnProgress = true; documents.status = ""
        documents.busy = true; error = ""; progress = 0
        releaseBusy = { [weak documents] in
            documents?.busy = false
            documents?.presentsOwnProgress = false
        }
        cancellation = AudioExportCancellation()
        let token = cancellation
        Task {
            defer {
                running = false
                // Do not release a different operation admitted after Cancel.
                releaseBusy?(); releaseBusy = nil
            }
            do {
                let (files, tracks) = try await Task.detached(priority: .utility) {
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
                } catch { for file in files { try? FileManager.default.removeItem(at: file) }; throw error }
                progress = 1; status = "Pronto — o original foi preservado e silenciado."
            } catch is CancellationError { status = "Separação cancelada." }
            catch {
                if token.cancelled { status = "Separação cancelada." }
                else { self.error = error.localizedDescription; status = "" }
            }
        }
    }
}

struct CatStemProgressView: View {
    @ObservedObject var session: CatStemSession
    let close: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Text(verbatim: "Separation audio").font(.jarasHeadline)
            Text(verbatim: session.status).fixedSize(horizontal: false, vertical: true)
            if !session.error.isEmpty { Text(verbatim: session.error).foregroundStyle(.red) }
            if session.running {
                ProgressView(value: session.progress)
                Button("Cancel") { session.cancel(); close() }.keyboardShortcut(.cancelAction)
            } else { Button("Close", action: close).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 400).interactiveDismissDisabled(session.running)
            .onDisappear { if session.running { session.cancel() } }
    }
}
