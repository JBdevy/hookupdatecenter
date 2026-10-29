#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor struct ProjectReductionView: View {
    @ObservedObject var documents: ProjectDocuments
    @ObservedObject private var show: ShowController
    init(documents: ProjectDocuments) { self.documents = documents; self.show = documents.show }
    @State private var ready = false
    @State private var restored = false
    @State private var saveTask: Task<Void, Never>?
    @State private var namingTarget: UUID?
    @State private var dragged: UUID?
    @State private var insertion: Int?
    @State private var dragScope = UUID()
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
            if !ready {
                Text("Salve o projeto antes de reduzir.").foregroundStyle(JarasTheme.yellow)
                Button("Salvar") { Task { await show.save(); ready = !needsSave } }.disabled(documents.show.saving)
            } else {
                Text("Selecione as origens à direita. Apenas as pistas escolhidas serão levadas; os áudios serão separados por região.")
                    .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Button { create() } label: { Label("Create Track", systemImage: "plus") }
                            Button("Editar", action: rename).disabled(selected == nil)
                            Button("Remover") {
                                groups.removeAll { $0.id == selected }; selected = nil; checked = []
                            }.disabled(selected == nil)
                        }
                        GeometryReader { area in
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                                    HStack {
                                        Button { selected = group.id; checked = group.sources } label: {
                                            HStack { Text(verbatim: group.name); Spacer(); Text("\(group.sources.count)").foregroundStyle(JarasTheme.secondary) }
                                                .padding(8).contentShape(Rectangle())
                                        }.buttonStyle(.plain)
                                    }.frame(height: 36)
                                        .background(selected == group.id ? JarasTheme.green.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                        .onDrag {
                                            dragged = group.id
                                            return NSItemProvider(object: ("reduction:" + dragScope.uuidString + ":" + group.id.uuidString) as NSString)
                                        } preview: {
                                            Text(verbatim: group.name).padding(5).background(Color.black)
                                        }
                                        .onDrop(of: [.text], delegate: ReductionTrackDrop(index: index, scope: dragScope,
                                            dragged: $dragged, insertion: $insertion, move: move))
                                        .overlay(alignment: .top) {
                                            if insertion == index { Rectangle().fill(JarasTheme.green).frame(height: 2).allowsHitTesting(false) }
                                        }
                                        .overlay(alignment: .bottom) {
                                            if index == groups.count - 1 && insertion == groups.count {
                                                Rectangle().fill(JarasTheme.green).frame(height: 2).allowsHitTesting(false)
                                            }
                                        }
                                }
                                Color.clear.frame(height: max(80, area.size.height - CGFloat(groups.count) * 40))
                                    .contentShape(Rectangle()).onTapGesture { finishEditing() }
                                    .onDrop(of: [.text], delegate: ReductionTrackDrop(index: groups.count, end: true, scope: dragScope,
                                        dragged: $dragged, insertion: $insertion, move: move))
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
                    .disabled(!ready || busy || groups.isEmpty || TrackRecording.shared.recording)
            }
            }
        }.padding(24).frame(width: 720)
            .background(JarasTheme.panel.contentShape(Rectangle()).onTapGesture { finishEditing() })
            .interactiveDismissDisabled(busy)
            .onAppear { restoreDraft(); ready = !needsSave; restored = true }
            .onChange(of: groups) { _ in saveDraft() }
            .onChange(of: checked) { _ in saveDraft() }
            .onChange(of: selected) { _ in saveDraft() }
            .onChange(of: show.saving) { saving in if !saving && !needsSave { ready = true } }
            .sheet(isPresented: $naming) {
                ReductionTrackNameEditor(initialName: name, editing: namingTarget != nil,
                    cancel: { naming = false }) { value in
                    if let target = namingTarget, let index = groups.firstIndex(where: { $0.id == target }) {
                        groups[index].name = value
                    } else if namingTarget == nil {
                        groups.append(ProjectReductionTrack(name: value, sources: checked)); checked = []; selected = nil
                    }
                    naming = false
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
        if let draft = ProjectReduction.Draft.read(from: show.snapshot.project)?.cleaned(for: show.snapshot.project) {
            groups = draft.groups; checked = draft.checked; selected = draft.selected
        } else if let data = try? Data(contentsOf: draftURL), let legacy = try? JSONDecoder().decode([ProjectReductionTrack].self, from: data) {
            let draft = ProjectReduction.Draft(groups: legacy).cleaned(for: show.snapshot.project)
            groups = draft.groups
        }
    }
    private func saveDraft() {
        guard restored, ready else { return }
        let draft = ProjectReduction.Draft(groups: groups, checked: checked, selected: selected)
        guard show.snapshot.project.reductionDraft != nil || !groups.isEmpty || !checked.isEmpty else { return }
        do { show.setReductionDraft(try draft.encoded()) }
        catch { self.error = error.localizedDescription; return }
        saveTask?.cancel()
        let show = show, session = show.projectSessionID
        saveTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
                while show.saving { try await Task.sleep(nanoseconds: 50_000_000) }
                guard !Task.isCancelled, show.projectSessionID == session, show.hasUnsavedChanges else { return }
                await show.save()
            } catch {}
        }
    }
    private func move(_ id: UUID, to offset: Int) {
        guard ready, !busy else { return }
        ProjectReduction.move(id, to: offset, in: &groups)
    }
    private func rename() {
        guard let group = groups.first(where: { $0.id == selected }) else { return }
        namingTarget = group.id; name = group.name; naming = true
    }
    private func finishEditing() {
        guard !busy, selected != nil else { return }
        selected = nil; checked = []
    }
    private func create() {
        if selected != nil { finishEditing(); return }
        guard !checked.isEmpty else { error = "Selecione as pistas de origem à direita."; return }
        error = ""; namingTarget = nil
        name = checked.count == 1 ? sources.first(where: { checked.contains($0.id) })?.name ?? "" : ""
        naming = true
    }
    private func reduce() {
        guard ready, let document = documents.currentURL else { return }
        do { try ProjectReduction.validate(groups, project: documents.show.snapshot.project) }
        catch { self.error = error.localizedDescription; return }
        error = ""; estimate = nil; choosingFormat = true
        let project = documents.show.snapshot.project, definitions = groups, media = document.deletingLastPathComponent()
        Task {
            do {
                while show.saving { try await Task.sleep(nanoseconds: 50_000_000) }
                if show.needsSave { try await show.flushProject() }
            } catch { self.error = error.localizedDescription; choosingFormat = false; return }
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

private struct ReductionTrackNameEditor: View {
    @State private var name: String
    @FocusState private var focused: Bool
    let editing: Bool
    let cancel: () -> Void
    let apply: (String) -> Void
    init(initialName: String, editing: Bool, cancel: @escaping () -> Void, apply: @escaping (String) -> Void) {
        _name = State(initialValue: initialName); self.editing = editing; self.cancel = cancel; self.apply = apply
    }
    private func confirm() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { apply(value) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nome da pista").font(.jarasTitle2.bold())
            TextField("Nome", text: $name).textFieldStyle(.roundedBorder).focused($focused).onSubmit(confirm)
            HStack {
                Button("Cancelar", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(LocalizedStringKey(editing ? "Salvar" : "Criar"), action: confirm)
                    .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 330).background(JarasTheme.panel)
            .onAppear { DispatchQueue.main.async { focused = true } }
    }
}
private struct ReductionTrackDrop: DropDelegate {
    let index: Int
    var end = false
    let scope: UUID
    @Binding var dragged: UUID?
    @Binding var insertion: Int?
    let move: (UUID, Int) -> Void
    private func offset(_ info: DropInfo) -> Int { index + (!end && info.location.y >= 18 ? 1 : 0) }
    func validateDrop(info: DropInfo) -> Bool { dragged != nil && info.hasItemsConforming(to: [.text]) }
    func dropEntered(info: DropInfo) { if validateDrop(info: info) { insertion = offset(info) } }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        insertion = offset(info); return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { insertion = nil }
    func performDrop(info: DropInfo) -> Bool {
        guard let id = dragged, let provider = info.itemProviders(for: [.text]).first else { return false }
        let target = offset(info), expected = "reduction:" + scope.uuidString + ":" + id.uuidString
        dragged = nil; insertion = nil
        _ = provider.loadObject(ofClass: String.self) { value, _ in
            guard value == expected else { return }
            DispatchQueue.main.async { move(id, target) }
        }
        return true
    }
}
#endif
