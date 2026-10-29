#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor struct IpadItemMenuCommand: Identifiable {
    var id: String { title }
    let title: String
    var destructive = false
    let action: () -> Void
}
@MainActor enum IpadItemContextMenu {
    static var commands: (UUID, Set<UUID>) -> [IpadItemMenuCommand] = { _, _ in [] }
}
@MainActor struct IpadItemMenuAnchor: UIViewRepresentable {
    let id: UUID
    func makeUIView(context: Context) -> IpadItemMenuAnchorView { IpadItemMenuAnchorView() }
    func updateUIView(_ view: IpadItemMenuAnchorView, context: Context) { view.item = id; IpadItemMenuAnchorView.anchors[id] = WeakAnchor(view) }
    static func dismantleUIView(_ view: IpadItemMenuAnchorView, coordinator: ()) {
        if let id = view.item, IpadItemMenuAnchorView.anchors[id]?.view === view { IpadItemMenuAnchorView.anchors.removeValue(forKey: id) }
    }
    final class WeakAnchor { weak var view: IpadItemMenuAnchorView?; init(_ view: IpadItemMenuAnchorView) { self.view = view } }
}
@MainActor final class IpadItemMenuAnchorView: UIView {
    static var anchors: [UUID: IpadItemMenuAnchor.WeakAnchor] = [:]
    var item: UUID?
    static func contains(_ touch: UITouch) -> Bool {
        anchors.values.contains { anchor in
            guard let view = anchor.view, view.window === touch.window, !view.isHidden else { return false }
            return view.bounds.contains(touch.location(in: view))
        }
    }
}

/// Context actions use the same project mutations and offline rendering as macOS.
@MainActor struct IpadItemActions: View {
    @ObservedObject var show: ShowController
    let documents: ProjectDocuments
    let item: UUID
    var targets: Set<UUID> = []
    let close: () -> Void
    var initialAction: String? = nil
    private let projectID: UUID
    private let songID: UUID?
    init(show: ShowController, documents: ProjectDocuments, item: UUID, targets: Set<UUID> = [], initialAction: String? = nil, close: @escaping () -> Void) {
        self.show = show; self.documents = documents; self.item = item; self.targets = targets; self.initialAction = initialAction; self.close = close
        projectID = show.snapshot.project.id; songID = show.current?.id
    }
    @State private var normalize = false
    @State private var editingText = false
    @State private var editingName = false
    @State private var exportingMIDI = false
    @State private var midiDocument: MIDIItemDocument?
    @State private var fx = false
    @State private var exporting = false
    @State private var locatingFile = false
    @StateObject private var processing = IpadItemProcessingSession()
    @StateObject private var separation = CatStemSession()
    @State private var separating = false
    private var entries: [(Track, AudioClip)] {
        guard show.snapshot.project.id == projectID, show.current?.id == songID else { return [] }
        let ids = targets.contains(item) ? targets : [item]
        return (show.current?.tracks ?? []).flatMap { track in
            track.clips.filter { ids.contains($0.id) }.map { (track, $0) }
        }
    }
    private var context: (Track, AudioClip)? { entries.first { $0.1.id == item } }
    private var standard: [(Track, AudioClip)] { entries.filter { $0.0.kind == .standard } }
    private var editableIDs: Set<UUID> { Set(standard.map { $0.1.id }) }
    private var audio: [(Track, AudioClip)] {
        entries.filter { track, clip in
            (track.kind == .standard || clip.isProjectionMedia) && clip.midi == nil && !clip.isImage && (clip.audioFile ?? track.audioFile) != nil
        }
    }
    private var audioIDs: Set<UUID> { Set(audio.map { $0.1.id }) }
    private var midiIDs: Set<UUID> { Set(standard.filter { $0.1.midi != nil }.map { $0.1.id }) }
    private var glueIDs: Set<UUID> {
        Set(standard.filter { $0.1.midi != nil || (!$0.1.isImage && ($0.1.audioFile ?? $0.0.audioFile) != nil) }.map { $0.1.id })
    }
    private var fileURL: URL? {
        guard entries.count == 1, let (track, clip) = context, clip.midi == nil,
              let file = clip.audioFile ?? track.audioFile,
              let directory = documents.currentURL?.deletingLastPathComponent() else { return nil }
        return URL(fileURLWithPath: file.path, relativeTo: directory).standardizedFileURL
    }
    private var childOpen: Bool { normalize || editingText || editingName || exportingMIDI || fx || exporting || processing.running || separating }
    private var actionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                IpadModalHeader(title: context?.1.name ?? "—", close: close)
                if entries.count > 1 { Text("\(entries.count) items").font(.jarasCaption).foregroundStyle(JarasTheme.secondary) }
                if let (track, clip) = context {
                    if entries.count == 1, clip.midi != nil || (clip.audioFile ?? track.audioFile) != nil {
                        action("Editar nome", symbol: "pencil") { editingName = true }
                    }
                    if entries.count == 1, clip.midi != nil { action("Exportar MIDI", symbol: "square.and.arrow.up") { exportMIDI() } }
                    if fileURL != nil { action("Open file location", symbol: "folder") { locatingFile = true } }
                    if track.kind.isText && !clip.isProjectionMedia { action("Edit", symbol: "text.alignleft") { editingText = true } }
                    if track.kind == .standard || clip.isProjectionMedia {
                        action("FX", symbol: "slider.horizontal.3") { fx = true }
                    }
                    if !editableIDs.isEmpty {
                        let muted = standard.allSatisfy { $0.1.muted == true }
                        action(muted ? "Unmute items" : "Mute items", symbol: muted ? "speaker.wave.2" : "speaker.slash") {
                            show.setItemsMix(editableIDs, muted: !muted)
                        }
                    }
                    if track.kind != .timecode {
                        action("Criar região do item", symbol: "rectangle.dashed") { show.regionsFromSelection(Set(entries.map { $0.1.id })); close() }
                    }
                    if !audio.isEmpty {
                        tuner
                        if entries.count == 1, AudioSeparation.accepts(clip, on: track) {
                            action("Separation audio", symbol: "waveform.path") { beginSeparation() }
                        }
                        action("Normalize…", symbol: "waveform") { normalize = true }
                        action("Re-render", symbol: "arrow.triangle.2.circlepath") {
                            processing.start(show: show, documents: documents, ids: audioIDs, operation: .render)
                        }
                    }
                    if !glueIDs.isEmpty {
                        action("Unify items", symbol: "rectangle.on.rectangle") {
                            processing.start(show: show, documents: documents, ids: glueIDs, operation: .glue)
                        }
                    }
                    if clip.midi != nil, !midiIDs.isEmpty {
                        action("Convert Mono", symbol: "waveform") { processing.start(show: show, documents: documents, ids: midiIDs, operation: .midi(channels: 1)) }
                        action("Convert Stereo", symbol: "waveform") { processing.start(show: show, documents: documents, ids: midiIDs, operation: .midi(channels: 2)) }
                    } else if !audioIDs.intersection(editableIDs).isEmpty {
                        Divider()
                        ForEach([4, 1, 2, 3, 0], id: \.self) { mode in
                            action(channelTitle(mode), symbol: (clip.channelMode ?? 0) == mode ? "checkmark.circle.fill" : "circle") {
                                _ = show.convertItems(audioIDs.intersection(editableIDs), mode: mode)
                            }
                        }
                    }
                    if !audioIDs.intersection(editableIDs).isEmpty { action("Export", symbol: "square.and.arrow.up") { exporting = true } }
                    if !processing.error.isEmpty { Text(verbatim: processing.error).font(.jarasCaption).foregroundStyle(.red) }
                    Button("Delete", role: .destructive) { show.deleteItems(Set(entries.map { $0.1.id })); close() }
                        .frame(maxWidth: .infinity, minHeight: 44).buttonStyle(.bordered)
                }
            }.padding(20)
        }
        .opacity(initialAction == nil ? 1 : 0)
        .background { if initialAction == nil { RemoteSurface.background } }
        .disabled(childOpen).accessibilityHidden(childOpen)
        .overlay { childEditor }
        .sheet(isPresented: $locatingFile) {
            if let fileURL { IpadItemFileBrowser(directory: fileURL.deletingLastPathComponent(), finished: { locatingFile = false }) }
        }
    }
    var body: some View {
        actionList.onAppear {
            switch initialAction {
            case "normalize": normalize = true
            case "fx": fx = true
            case "text": editingText = true
            case "name": editingName = true
            case "exportMIDI": exportMIDI()
            case "file": locatingFile = true
            case "separate": beginSeparation()
            case "render": processing.start(show: show, documents: documents, ids: audioIDs, operation: .render)
            case "midiMono": processing.start(show: show, documents: documents, ids: midiIDs, operation: .midi(channels: 1))
            case "midiStereo": processing.start(show: show, documents: documents, ids: midiIDs, operation: .midi(channels: 2))
            case "tuner": break
            case "glue": processing.start(show: show, documents: documents, ids: glueIDs, operation: .glue)
            default: break
            }
        }
        .onChange(of: locatingFile) { if !$0 && initialAction == "file" { close() } }
        .onChange(of: normalize) { if !$0 && initialAction == "normalize" { close() } }
        .onChange(of: fx) { if !$0 && initialAction == "fx" { close() } }
        .fileExporter(isPresented: $exportingMIDI, document: midiDocument, contentType: MIDIItemDocument.readableContentTypes[0], defaultFilename: context?.1.name ?? "Item") { result in
            if case .failure(let error) = result { show.message = error.localizedDescription }
            midiDocument = nil; if initialAction == "exportMIDI" { close() }
        }
        .onChange(of: editingName) { if !$0 && initialAction == "name" { close() } }
        .onChange(of: editingText) { if !$0 && initialAction == "text" { close() } }
        .onChange(of: processing.running) { running in
            if !running, processing.error.isEmpty, ["render", "glue", "midiMono", "midiStereo"].contains(initialAction ?? "") { close() }
        }
        .onChange(of: processing.finished) { if $0 { close() } }
        .onChange(of: show.snapshot.project.id) { if $0 != projectID { processing.cancel(); close() } }
        .onChange(of: show.current?.id) { if $0 != songID { processing.cancel(); close() } }
        .onDisappear { processing.cancel(); separation.cancel() }
    }
    private func exportMIDI() {
        guard entries.count == 1, let clip = context?.1 else { return }
        do { midiDocument = try MIDIItemDocument(clip: clip); exportingMIDI = true }
        catch { show.message = error.localizedDescription; close() }
    }
    private func channelTitle(_ mode: Int) -> String {
        switch mode { case 4: return "Swap - LR"; case 1: return "Convert Mono - L"; case 2: return "Convert Mono - R"; case 3: return "Convert Mono L-R"; default: return "Convert Stereo" }
    }
    private var tuner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Tuner").font(.jarasHeadline)
            ForEach(audio.map { $0.1 }) { clip in
                HStack(spacing: 8) {
                    Text(verbatim: clip.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Button { show.setItemPitch(clip.id, semitones: max(-12, (clip.pitchSemitones ?? 0) - 1)) } label: { Image(systemName: "minus").frame(width: 34, height: 34) }
                    Text(verbatim: String(format: "%+.2g st", clip.pitchSemitones ?? 0)).monospacedDigit().frame(width: 54)
                    Button { show.setItemPitch(clip.id, semitones: min(12, (clip.pitchSemitones ?? 0) + 1)) } label: { Image(systemName: "plus").frame(width: 34, height: 34) }
                }
            }
        }.padding(10).background(JarasTheme.display, in: RoundedRectangle(cornerRadius: 7))
    }
    private func beginSeparation() {
        separating = true; separation.start(item: item, show: show, documents: documents)
    }
    @ViewBuilder private var childEditor: some View {
        if separating {
            IpadCompactModal {
                CatStemProgressView(session: separation) {
                    separating = false
                    if initialAction == "separate" { close() }
                }
            }
        } else if initialAction == "tuner" {
            IpadCompactModal { VStack { tuner; Button("Close", action: close) }.padding(18).frame(width: 320) }
        } else if !processing.error.isEmpty {
            IpadCompactModal {
                VStack(spacing: 16) { Text(verbatim: processing.error); Button("Close", action: close) }.padding(18).frame(width: 320)
            }
        } else if processing.running {
            IpadCompactModal {
                VStack(spacing: 16) {
                    Text(LocalizedStringKey(processing.title)).font(.jarasHeadline)
                    Text(verbatim: processing.fileName).lineLimit(2)
                    ProgressView(value: processing.fraction).progressViewStyle(JarasProgressBarStyle())
                    Button("Cancel") { processing.cancel() }
                }.padding(24).frame(width: 380)
            }
        } else if editingName, let clip = context?.1 {
            IpadCompactModal {
                ItemNameEditor(name: clip.name, apply: { show.renameItem(item, name: $0) }, close: { editingName = false })
            }
        } else if editingText {
            IpadCompactModal {
                TextItemEditor(text: context?.1.text ?? "", apply: { show.updateTextItem(item, text: $0) }, close: { editingText = false })
            }
        } else if normalize {
            IpadCompactModal { ItemNormalizationEditor(show: show, documents: documents, items: audioIDs, close: { normalize = false }) }
        } else if fx {
            IpadCompactModal(preferredSize: CGSize(width: 980, height: 640)) {
                IpadStandaloneFXManager(show: show, track: nil, clip: item, targets: [], close: { fx = false })
            }
        } else if exporting, let song = show.current {
            IpadCompactModal(preferredSize: CGSize(width: 540, height: 480)) {
                IpadItemExportEditor(request: .init(project: show.snapshot.project, song: song,
                    items: audioIDs.intersection(editableIDs), mediaDirectory: documents.currentURL?.deletingLastPathComponent()), close: { exporting = false })
            }
        }
    }
    private func action(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack { Image(systemName: symbol).frame(width: 20); Text(LocalizedStringKey(title)); Spacer() }
                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 40).contentShape(Rectangle())
        }.buttonStyle(StageButtonStyle(color: JarasTheme.panel))
    }
}

@MainActor private final class IpadItemProcessingSession: ObservableObject {
    enum Operation { case render, glue, midi(channels: Int) }
    @Published var running = false
    @Published var finished = false
    @Published var title = "Re-render"
    @Published var fileName = ""
    @Published var fraction = 0.0
    @Published var error = ""
    private var cancellation: AudioExportCancellation?
    private var task: Task<Void, Never>?
    func cancel() { cancellation?.cancel() }
    func start(show: ShowController, documents: ProjectDocuments, ids: Set<UUID>, operation: Operation) {
        guard !running, show.canControl(), !documents.busy, !ids.isEmpty,
              let song = show.current, let directory = documents.currentURL?.deletingLastPathComponent() else { return }
        let entries = song.tracks.flatMap { track in track.clips.filter { ids.contains($0.id) }.map { (track, $0) } }
        guard !entries.isEmpty else { return }
        let token = AudioExportCancellation(), project = show.snapshot.project
        let instruments = Dictionary(uniqueKeysWithValues: song.tracks.filter { track in entries.contains { $0.0.id == track.id } }
            .map { ($0.id, ItemReRender.midiInstruments(for: $0, projectDirectory: directory)) })
        let settings = MediaProcessingFormat.load("rerender")
        cancellation = token; running = true; finished = false; error = ""; fraction = 0
        title = { if case .glue = operation { return "Unify items" }; return "Re-render" }()
        fileName = entries[0].1.name; documents.busy = true
        task = Task {
            defer { documents.busy = false; running = false; task = nil; cancellation = nil }
            do {
                if case .glue = operation {
                    let replacements = try await Task.detached(priority: .utility) {
                        try ItemReRender.glueSelection(project: project, song: song, ids: ids, directory: directory,
                            cancellation: token, instruments: instruments) { index, total, update in
                                Task { @MainActor in
                                    guard !token.cancelled, self.cancellation === token else { return }
                                    self.fileName = update.fileName
                                    self.fraction = (Double(index) + update.fraction) / Double(max(1, total))
                                }
                            }
                    }.value
                    guard !token.cancelled, show.replaceGluedItems(replacements, project: project.id, song: song.id) else {
                        ItemReRender.discardGluedAudio(replacements, directory: directory)
                        if !token.cancelled { error = JarasLocalization.string("The selected items changed while unifying.") }
                        return
                    }
                } else {
                    for (index, entry) in entries.enumerated() {
                        if token.cancelled { return }
                        let (track, clip) = entry
                        fileName = clip.name
                        let result = try await Task.detached(priority: .utility) {
                            let update: (AudioExportProgress) -> Void = { progress in
                                Task { @MainActor in
                                    guard !token.cancelled, self.cancellation === token else { return }
                                    self.fileName = progress.fileName
                                    self.fraction = (Double(index) + progress.fraction) / Double(entries.count)
                                }
                            }
                            if case .midi(let channels) = operation {
                                return try ItemReRender.renderMIDI(project: project, song: song, track: track, clip: clip,
                                    directory: directory, channels: channels, instruments: instruments[track.id] ?? [:], cancellation: token, progress: update)
                            }
                            return try ItemReRender.render(project: project, song: song, track: track, clip: clip,
                                directory: directory, settings: settings, cancellation: token, progress: update)
                        }.value
                        guard !token.cancelled, show.replaceRenderedItem(result, original: clip, track: track.id, project: project.id) else {
                            if let path = result.audioFile?.path, path != clip.audioFile?.path, path.hasPrefix("Stems/") {
                                try? FileManager.default.removeItem(at: directory.appendingPathComponent(path))
                            }
                            if !token.cancelled { error = JarasLocalization.string(show.message.isEmpty ? "The audio item changed during Re-render." : show.message) }
                            return
                        }
                    }
                }
                finished = true
            } catch is CancellationError { }
            catch { self.error = JarasLocalization.string(error.localizedDescription) }
        }
    }
}

@MainActor private struct IpadItemExportEditor: View {
    let request: ItemAudioExportRequest
    let close: () -> Void
    @StateObject private var session = IpadItemExportSession()
    @AppStorage("jaras.export.format") private var format = AudioExportFormat.wav
    @AppStorage("jaras.export.bits") private var bits = 24
    @AppStorage("jaras.export.bitrate") private var bitrate = 320
    @AppStorage("jaras.export.sampleRate") private var rate = 48000.0
    @AppStorage("jaras.export.itemChannels") private var channels = 0
    @State private var choosingDestination = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            IpadModalHeader(title: "Export audio items", close: { if !session.running { close() } })
            VStack(spacing: 12) {
                Picker("Format", selection: $format) { ForEach(AudioExportFormat.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) } }
                if format == .mp3 {
                    Picker("Bitrate", selection: $bitrate) { ForEach([128, 160, 192, 224, 256, 320], id: \.self) { Text(verbatim: "\($0) kbps").tag($0) } }
                } else {
                    Picker("Bit depth", selection: $bits) { ForEach([16, 24, 32], id: \.self) { Text(verbatim: "\($0) bit PCM").tag($0) } }
                }
                Picker("Sample rate", selection: $rate) { Text(verbatim: "44.1 kHz").tag(44100.0); Text(verbatim: "48 kHz").tag(48000.0) }
                Picker("Channels", selection: $channels) { Text("Original").tag(0); Text("Stereo").tag(2); Text("Mono").tag(1) }
            }.disabled(session.running)
            if session.running { Text(verbatim: session.fileName).lineLimit(2); ProgressView(value: session.fraction).progressViewStyle(JarasProgressBarStyle()) }
            if !session.error.isEmpty { Text(verbatim: session.error).foregroundStyle(.red).font(.jarasCaption) }
            HStack {
                Button(session.running ? "Cancel" : "Close") { if session.running { session.cancel() } else { close() } }
                Spacer()
                Button("Export") {
                    session.start(request: request, encoding: AudioExportEncoding(format: format, bitDepth: bits,
                        channels: channels, bitrate: bitrate, sampleRate: rate), rate: rate)
                }.buttonStyle(.borderedProminent).tint(JarasTheme.green).disabled(session.running)
            }
        }.padding(22)
            .onChange(of: session.ready) { if $0 { choosingDestination = true } }
            .sheet(isPresented: $choosingDestination, onDismiss: { session.clearOutput() }) {
                IpadItemFileExporter(urls: session.files, finished: { choosingDestination = false })
            }
            .onDisappear { session.cancel(); if !choosingDestination { session.clearOutput() } }
    }
}

@MainActor private final class IpadItemExportSession: ObservableObject {
    @Published var running = false
    @Published var ready = false
    @Published var fraction = 0.0
    @Published var fileName = ""
    @Published var error = ""
    private(set) var files: [URL] = []
    private var folder: URL?
    private var cancellation: AudioExportCancellation?
    func cancel() { cancellation?.cancel() }
    func clearOutput() {
        guard !running else { return }
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil; files = []; ready = false
    }
    func start(request: ItemAudioExportRequest, encoding: AudioExportEncoding, rate: Double) {
        guard !running, let media = request.mediaDirectory else { return }
        clearOutput()
        let plan = AudioExportPlan(project: request.project, song: request.song, source: .stems, bounds: .project,
            template: "%stem", tracks: [], clips: request.items, regions: [], format: encoding.format)
        guard !plan.jobs.isEmpty else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CatLive-item-export-" + UUID().uuidString, isDirectory: true)
        let token = AudioExportCancellation()
        let instruments = Dictionary(uniqueKeysWithValues: request.song.tracks.filter { $0.clips.contains { $0.midi != nil } }
            .map { ($0.id, ItemReRender.midiInstruments(for: $0, projectDirectory: media)) })
        folder = directory; cancellation = token; running = true; ready = false; error = ""; fraction = 0
        Task {
            defer { running = false; cancellation = nil; if token.cancelled { clearOutput() } }
            do {
                try await Task.detached(priority: .utility) {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try OfflineAudioExport.run(project: request.project, song: request.song, plan: plan,
                        mediaDirectory: media, outputDirectory: directory, sampleRate: rate, encoding: encoding,
                        cancellation: token, midiInstrumentsByTrack: instruments) { update in
                            Task { @MainActor in
                                guard !token.cancelled, self.cancellation === token else { return }
                                self.fileName = update.fileName
                                self.fraction = (Double(update.completed) + update.fraction) / Double(max(1, update.total))
                            }
                        }
                }.value
                guard !token.cancelled else { return }
                files = plan.jobs.map { directory.appendingPathComponent($0.fileName) }; ready = true
            } catch is CancellationError { }
            catch { self.error = JarasLocalization.string(error.localizedDescription) }
        }
    }
}

private struct IpadItemFileExporter: UIViewControllerRepresentable {
    let urls: [URL]
    let finished: () -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finished: () -> Void
        init(finished: @escaping () -> Void) { self.finished = finished }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finished() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finished() }
    }
}

/// Files presents the source directory; selecting a file never replaces media.
private struct IpadItemFileBrowser: UIViewControllerRepresentable {
    let directory: URL
    let finished: () -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.directoryURL = directory; picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finished: () -> Void
        init(finished: @escaping () -> Void) { self.finished = finished }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finished() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finished() }
    }
}
#endif
