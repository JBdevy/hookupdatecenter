#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor struct ProjectReductionView: View {
    @ObservedObject var documents: ProjectDocuments
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [ProjectReductionTrack] = []
    @State private var selected: UUID?
    @State private var checked = Set<UUID>()
    @State private var name = ""
    @State private var naming = false
    @State private var choosingFormat = false
    @State private var format: AudioExportFormat = .wav
    @State private var bitDepth = 32
    @State private var sampleRate = 48000.0
    @State private var bitrate = 320
    @State private var estimate: ProjectReduction.SizeEstimate?
    @State private var busy = false
    @State private var progress = 0.0
    @State private var progressMessage = ""
    @State private var error = ""
    @State private var result: URL?
    @State private var cancellation = AudioExportCancellation()
    private var needsSave: Bool { documents.currentURL == nil || documents.show.needsSave || documents.show.saving }
    private var sources: [Track] { ProjectReduction.sourceTracks(in: documents.show.snapshot.project) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if choosingFormat { formatSelection } else {
            Text("Reduzir projeto").font(.jarasTitle2.bold())
            if needsSave {
                Text("Salve o projeto antes de reduzir.").foregroundStyle(JarasTheme.yellow)
                Button("Salvar") { Task { await documents.show.save() } }.disabled(documents.show.saving)
            } else {
                Text("Selecione as origens à direita. Apenas as pistas escolhidas serão levadas; os áudios serão separados por região.")
                    .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button { create() } label: { Label("Create Track", systemImage: "plus") }
                        GeometryReader { area in
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(groups) { group in
                                    HStack {
                                        Button { selected = group.id; checked = group.sources } label: {
                                            HStack { Text(verbatim: group.name); Spacer(); Text("\(group.sources.count)").foregroundStyle(JarasTheme.secondary) }
                                                .padding(8).contentShape(Rectangle())
                                        }.buttonStyle(.plain)
                                        Button { groups.removeAll { $0.id == group.id }; if selected == group.id { selected = nil; checked = [] } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                                    }.background(selected == group.id ? JarasTheme.green.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                }
                                Color.clear.frame(height: max(80, area.size.height - CGFloat(groups.count) * 40))
                                    .contentShape(Rectangle()).onTapGesture { finishEditing() }
                            }.frame(maxWidth: .infinity)
                        }
                        }
                    }.frame(maxWidth: .infinity)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(sources) { track in
                                let used = groups.contains { $0.id != selected && $0.sources.contains(track.id) }
                                Toggle(isOn: Binding(get: { checked.contains(track.id) }, set: { on in
                                    if on { checked.insert(track.id) } else { checked.remove(track.id) }
                                    if let index = groups.firstIndex(where: { $0.id == selected }) { groups[index].sources = checked }
                                })) { Text(verbatim: track.name).frame(maxWidth: .infinity, alignment: .leading) }.disabled(used)
                                    .overlay(alignment: .leading) {
                                        if !used && !busy {
                                            RoundedRectangle(cornerRadius: 4).strokeBorder(JarasTheme.green, lineWidth: 1.5)
                                                .frame(width: 16, height: 16).allowsHitTesting(false)
                                        }
                                    }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxWidth: .infinity)
                }.frame(height: 340).disabled(busy)
                if busy {
                    HStack {
                        ProgressView(value: progress).tint(JarasTheme.green)
                        Text("\(Int(progress * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    Text(verbatim: progressMessage).font(.jarasCaption)
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
                }
                if let result { Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([result]) } }
            }
            if !error.isEmpty { Text(verbatim: error).foregroundStyle(.red).font(.jarasCaption) }
            HStack {
                Button("Cancelar") { if busy { cancellation.cancel() } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Reduzir", action: reduce).buttonStyle(StageButtonStyle(color: JarasTheme.green))
                    .disabled(needsSave || busy || groups.isEmpty || TrackRecording.shared.recording)
            }
            }
        }.padding(24).frame(width: 720)
            .background(JarasTheme.panel.contentShape(Rectangle()).onTapGesture { finishEditing() })
            .interactiveDismissDisabled(busy)
            .onAppear { restoreDraft() }
            .onChange(of: groups) { _ in saveDraft() }
            .alert("Nome da pista", isPresented: $naming) {
                TextField("Nome", text: $name)
                Button("Cancelar", role: .cancel) {}
                Button("Criar") {
                    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { groups.append(ProjectReductionTrack(name: value, sources: checked)); checked = []; selected = nil }
                }
            }
    }
    private var formatSelection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Formato do projeto reduzido").font(.jarasTitle2.bold())
            Text("Tamanho aproximado do projeto, incluindo as mídias que serão copiadas.")
                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
            ForEach(AudioExportFormat.allCases, id: \.self) { option in
                Button { format = option } label: {
                    HStack {
                        Image(systemName: format == option ? "largecircle.fill.circle" : "circle")
                        Text(verbatim: option.rawValue).bold().frame(width: 55, alignment: .leading)
                        Text(verbatim: option == .mp3 ? "\(bitrate) kbps · estéreo" : "\(bitDepth)-bit\(bitDepth == 32 ? " float" : "") · estéreo")
                        Spacer()
                        if let estimate { Text(verbatim: String(format: "≈ %.2f GB", estimate.bytes(for: option, bitDepth: bitDepth, sampleRate: sampleRate, bitrate: bitrate) / 1e9)).monospacedDigit() }
                        else { ProgressView().controlSize(.small) }
                    }.padding(12).contentShape(Rectangle())
                }.buttonStyle(.plain).background(format == option ? JarasTheme.green.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 20) {
                if format == .mp3 {
                    Picker("Bitrate", selection: $bitrate) {
                        ForEach([128,160,192,224,256,320], id: \.self) { Text("\($0) kbps").tag($0) }
                    }
                } else {
                    Picker("Bits", selection: $bitDepth) {
                        ForEach([16,24,32], id: \.self) { Text($0 == 32 ? "32-bit float" : "\($0)-bit").tag($0) }
                    }
                }
                Picker("Frequência", selection: $sampleRate) {
                    Text("44.100 Hz").tag(44100.0)
                    Text("48.000 Hz").tag(48000.0)
                }
            }
            Text("O formato vale para os áudios renderizados. Pistas individuais mantidas sem renderização conservam os arquivos originais. MP3 usa compressão com perda.")
                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
            HStack {
                Button("Voltar") { choosingFormat = false }
                Spacer()
                Button("Escolher local…") { chooseDestination() }.buttonStyle(StageButtonStyle(color: JarasTheme.green)).disabled(estimate == nil)
            }
        }
    }
    private var draftURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CatLive/ProjectReduction", isDirectory: true)
            .appendingPathComponent(documents.show.snapshot.project.id.uuidString + ".json")
    }
    private func restoreDraft() {
        guard groups.isEmpty, let data = try? Data(contentsOf: draftURL),
              let draft = try? JSONDecoder().decode([ProjectReductionTrack].self, from: data) else { return }
        let available = Set(sources.map(\.id))
        groups = draft.map { group in var group = group; group.sources.formIntersection(available); return group }
    }
    private func saveDraft() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        try? FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: draftURL, options: .atomic)
    }
    private func finishEditing() {
        guard !busy, selected != nil else { return }
        selected = nil; checked = []
    }
    private func create() {
        if selected != nil { finishEditing(); return }
        guard !checked.isEmpty else { error = "Selecione as pistas de origem à direita."; return }
        error = ""; name = ""; naming = true
    }
    private func reduce() {
        guard !needsSave, let document = documents.currentURL else { return }
        do { try ProjectReduction.validate(groups, project: documents.show.snapshot.project) }
        catch { self.error = error.localizedDescription; return }
        error = ""; estimate = nil; choosingFormat = true
        let project = documents.show.snapshot.project, definitions = groups, media = document.deletingLastPathComponent()
        Task {
            let value = await Task.detached(priority: .userInitiated) {
                ProjectReduction.estimate(definitions, project: project) { path in
                    Double((try? media.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }.value
            estimate = value
        }
    }
    private func chooseDestination() {
        guard !needsSave, let document = documents.currentURL else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "jl") ?? .data]
        panel.nameFieldStringValue = document.deletingPathExtension().lastPathComponent + " - Reduzido.jl"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        choosingFormat = false
        let selectedFormat = format, selectedBits = bitDepth, selectedRate = sampleRate, selectedBitrate = bitrate
        let target = ProjectDirectoryPolicy.newProjectDestination(for: chosen)
        let project = documents.show.snapshot.project, media = document.deletingLastPathComponent(), definitions = groups
        let instruments = Dictionary(uniqueKeysWithValues: project.songs.flatMap(\.tracks).filter { $0.clips.contains { $0.midi != nil } }.map { ($0.id, ItemReRender.midiInstruments(for: $0, projectDirectory: media)) })
        cancellation = AudioExportCancellation(); let token = cancellation
        busy = true; progress = 0; progressMessage = "Preparando redução…"; error = ""; result = nil
        Task {
            defer { busy = false }
            do {
                guard !documents.show.needsSave else { throw ProjectError.invalid("Salve o projeto antes de reduzir.") }
                try await Task.detached(priority: .userInitiated) {
                    try ReducedProjectWriter.write(project: project, groups: definitions, media: media, target: target, instruments: instruments, cancellation: token, format: selectedFormat, bitDepth: selectedBits, sampleRate: selectedRate, bitrate: selectedBitrate) { value in
                        DispatchQueue.main.async {
                            if value.fraction >= progress {
                                progress = value.fraction; progressMessage = value.message
                            }
                        }
                    }
                }.value
                result = target
            } catch { self.error = error.localizedDescription }
        }
    }
}

#endif
