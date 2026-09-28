import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

@MainActor final class ProjectDocuments: ObservableObject {
    @Published var ready = false
    @Published var opened = UUID()
    @Published var currentURL: URL?
    @Published var recent: [URL] = []
    @Published var busy = false
    @Published var status = ""
    @Published var error = ""
    @Published var folderReview: [URL]?
    @Published var scan: StemScan?
    @Published var removal = ""
    @Published var warnings: [String] = []
    @Published var importingAudio = false
    @Published var audioImportError = ""
    struct PendingAudioDrop: Identifiable {
        let id = UUID()
        let providers: [NSItemProvider]
        let start: Double
        let track: UUID?
        let song: UUID
        let project: UUID
    }
    @Published var pendingAudioDrop: PendingAudioDrop?
    func importAudio(_ providers: [NSItemProvider], start: Double, track: UUID?, song: UUID, layout: AudioDropLayout? = nil, gap: Double = 0) -> Bool {
        guard ready, !busy, !providers.isEmpty, let destination = currentURL,
              let arrangement = show.snapshot.project.songs.first(where: { $0.id == song }) else { return false }
        let projectID = show.snapshot.project.id
        if let track, !arrangement.tracks.contains(where: { $0.id == track }) {
            audioImportError = "The destination track no longer exists"; return false
        }
        let destinationKind = track.flatMap { id in arrangement.tracks.first { $0.id == id }?.kind }
        guard destinationKind != .timecode, destinationKind != .chords else {
            audioImportError = "Drop media on an audio, Video or Teleprompter track"; return false
        }
        if providers.count > 1, layout == nil {
            pendingAudioDrop = PendingAudioDrop(providers: providers, start: start, track: track, song: song, project: projectID)
            return true
        }
        let targets = track.flatMap { id in arrangement.tracks.contains { $0.id == id } ? [id] : nil } ?? []
        let dropLayout = layout ?? .separateTracks
        let videoTrackAvailable = arrangement.tracks.contains { $0.kind == .video }
        busy = true; importingAudio = true; status = "Importing audio…"; audioImportError = ""
        Task {
            defer { busy = false; importingAudio = false }
            var prepared: StemProjectImporter.DroppedAudio?
            do {
                var urls: [URL] = []
                for provider in providers {
                    let url: URL = try await withCheckedThrowingContinuation { continuation in
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                            if let error { continuation.resume(throwing: error); return }
                            let url: URL?
                            if let value = item as? URL { url = value }
                            else if let value = item as? Data { url = URL(dataRepresentation: value, relativeTo: nil) }
                            else if let value = item as? String { url = URL(string: value) }
                            else { url = nil }
                            if let url, url.isFileURL { continuation.resume(returning: url) }
                            else { continuation.resume(throwing: ProjectError.invalid("Could not read the dropped file.")) }
                        }
                    }
                    urls.append(url)
                }
                let sources = urls
                prepared = try await Task.detached(priority: .userInitiated) {
                    try StemProjectImporter.prepareDroppedAudio(sources, start: start, destinationTracks: targets, destination: destination, layout: dropLayout, gap: gap, destinationKind: destinationKind, videoTrackAvailable: videoTrackAvailable) { [weak self] current, total, name in
                        Task { @MainActor [weak self] in self?.status = "Importing \(current)/\(total): \(name)" }
                    }
                }.value
                if let prepared {
                    for imported in prepared.tracks where imported.kind == .video || imported.kind == .teleprompt {
                        guard show.snapshot.project.songs.first(where: { $0.id == song })?.tracks.contains(where: { $0.id == imported.id && $0.kind == imported.kind }) == true else {
                            throw ProjectError.invalid("The destination Video track no longer exists")
                        }
                    }
                    try show.insertAudioTracks(prepared.tracks, song: song, project: projectID)
                }
            } catch {
                if let prepared { for folder in prepared.folders { try? FileManager.default.removeItem(at: folder) } }
                audioImportError = formattedImportError(error)
            }
        }
        return true
    }
    private func formattedImportError(_ error: Error) -> String {
        let message = error.localizedDescription
        for (prefix, key) in [("Unsupported media file: ", "Unsupported media file: %@"),
                              ("Empty media file: ", "Empty media file: %@")] {
            if message.hasPrefix(prefix) {
                return String(format: JarasLocalization.string(key), String(message.dropFirst(prefix.count)))
            }
        }
        return message
    }
    func chooseVideo(track: UUID) {
        #if os(macOS)
        guard let song = show.current else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie, .image]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        _ = importAudio(panel.urls.map { NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier) }, start: show.snapshot.transport.editPosition ?? show.snapshot.transport.position, track: track, song: song.id, layout: .sameTrack)
        #endif
    }
    private var adding = false
    private var addTarget: (project: Project, url: URL)?
    private let store: DocumentProjectStore
    let show: ShowController
    init(store: DocumentProjectStore, show: ShowController, preview: Bool) {
        self.store = store; self.show = show; ready = preview
        recent = (UserDefaults.standard.stringArray(forKey: "jaras.recentProjects") ?? []).map { URL(fileURLWithPath: $0) }
    }
    private func remember(_ url: URL) {
        ProjectDocumentAppearance.apply(to: url)
        recent.removeAll { $0 == url }; recent.insert(url, at: 0); recent = Array(recent.prefix(20))
        UserDefaults.standard.set(recent.map(\.path), forKey: "jaras.recentProjects")
    }
    func cleanupClosedProject(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard ready, let currentURL, !show.hasUnsavedChanges else { progress(1); return }
        let project = show.snapshot.project, known = show.knownMediaPaths
        show.send(.stopAll)
        VideoPlayback.shared.open(directory: currentURL.deletingLastPathComponent())
        VideoPlayback.teleprompter.open(directory: currentURL.deletingLastPathComponent())
        try await Task.detached(priority: .utility) {
            try ProjectMediaCleanup.close(project: project, document: currentURL, knownPaths: known, progress: progress)
        }.value
        show.discardClosedHistory()
    }
    private func activate(_ project: Project, at url: URL) async throws {
        try project.validate()
        if ready && show.hasUnsavedChanges { try await show.flushProject() }
        if currentURL != url { try await cleanupClosedProject() }
        await store.select(url: url, id: project.id)
        try show.replaceProject(project)
        StemAudioPlayback.shared.open(directory: url.deletingLastPathComponent())
        VideoPlayback.shared.open(directory: url.deletingLastPathComponent())
        VideoPlayback.teleprompter.open(directory: url.deletingLastPathComponent())
        #if os(macOS)
        TeleprompterRemote.shared.setDirectory(url.deletingLastPathComponent())
        #endif
        VideoPlayback.shared.update(show.snapshot)
        TrackRecording.shared.open(directory: url.deletingLastPathComponent(), project: show.snapshot.project.id)
        show.preparePlayback()
        currentURL = url; remember(url); ready = true; opened = UUID()
    }
    func open(_ url: URL) {
        guard !busy, !show.isPlaying, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        busy = true; error = ""; status = "Opening project…"
        Task {
            defer { busy = false }
            do {
                guard ["jl", "bkjl"].contains(url.pathExtension.lowercased()) else { throw ProjectError.invalid("Select a .jl or .bkjl project") }
                let url = try await Task.detached(priority: .userInitiated) {
                    try url.pathExtension.lowercased() == "bkjl" ? ProjectBackups.restore(url) : url
                }.value
                guard let project = try await ProjectStore(url: url).load() else { throw ProjectError.invalid("Project not found") }
                status = "Preparing waveforms…"
                let enriched = try await Task.detached(priority: .userInitiated) {
                    try StemProjectImporter.populateChannelOverviews(project, directory: url.deletingLastPathComponent())
                }.value
                if enriched != project { try await ProjectStore(url: url).save(enriched) }
                try await activate(enriched, at: url)
            } catch { self.error = error.localizedDescription }
        }
    }
    func browse() {
        #if os(macOS)
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "jl") ?? .data, UTType(filenameExtension: "bkjl") ?? .data]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
        #endif
    }
    func addProject() {
        guard !busy, !show.isPlaying, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        if ready { addTarget = nil; chooseStems(adding: true); return }
        #if os(macOS)
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "jl") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; error = ""
        Task {
            do {
                guard let project = try await ProjectStore(url: url).load() else { throw ProjectError.invalid("Project not found") }
                addTarget = (project, url); busy = false; chooseStems(adding: true)
            } catch { busy = false; self.error = error.localizedDescription }
        }
        #endif
    }
    func chooseStems(adding: Bool) {
        guard !busy, !show.isPlaying, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        #if os(macOS)
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        self.adding = adding; error = ""; warnings = []; scan = nil
        let urls = panel.urls
        if urls.count > 1 { folderReview = urls }
        else { analyzeFolders(urls) }
        #endif
    }
    func confirmFolders(_ urls: [URL]) {
        guard let available = folderReview, !urls.isEmpty, urls.allSatisfy(available.contains), !busy else { return }
        folderReview = nil
        analyzeFolders(urls)
    }
    private func analyzeFolders(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        busy = true; error = ""; warnings = []; status = "Analyzing audio and names…"
        Task {
            defer { busy = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) { try StemProjectImporter.scan(urls) }.value
                scan = result; removal = ""; warnings = result.warnings
            } catch { self.error = error.localizedDescription }
        }
    }
    func createEmpty() { finish(scan: nil) }
    func confirmImport() { guard let scan else { return }; finish(scan: scan) }
    private func finish(scan: StemScan?) {
        guard !busy, !show.isPlaying, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        #if os(macOS)
        let append = scan != nil && adding && (ready || addTarget != nil)
        let url: URL
        if append, let target = addTarget?.url ?? currentURL { url = target }
        else {
            let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "jl") ?? .data]
            panel.nameFieldStringValue = "Untitled.jl"; panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let selected = panel.url else { return }
            url = selected.pathExtension.lowercased() == "jl" ? selected : selected.appendingPathExtension("jl")
            guard !FileManager.default.fileExists(atPath: url.path) else { error = "A project already exists at this location. Choose another name."; return }
        }
        let base = append ? (addTarget?.project ?? show.snapshot.project) : Project.empty(name: url.deletingPathExtension().lastPathComponent)
        let remove = removal
        busy = true; error = ""; status = "Copying audio and saving project…"
        Task {
            defer { busy = false }
            do {
                // Flush the previous document before replacing it or appending media.
                if ready && show.hasUnsavedChanges { try await show.flushProject() }
                let result = try await Task.detached(priority: .userInitiated) {
                    let project = try scan.map { try StemProjectImporter.build(scan: $0, remove: remove, base: base, destination: url, progress: { [weak self] current, total, name in
                        Task { @MainActor [weak self] in self?.status = "Importing \(current)/\(total): \(name)" }
                    }) } ?? base
                    try project.validate()
                    let data = try ProjectDocumentCodec.encode(project)
                    do { try ProjectDocumentCodec.writeEncoded(data, to: url, exclusive: !append) }
                    catch {
                        let existing = Set(base.songs.flatMap(\.tracks).flatMap(\.clips).compactMap { $0.audioFile?.path })
                        let imported = project.songs.flatMap(\.tracks).flatMap(\.clips).compactMap { $0.audioFile?.path }.filter { !existing.contains($0) }
                        for folder in Set(imported.map { url.deletingLastPathComponent().appendingPathComponent($0).deletingLastPathComponent() }) { try? FileManager.default.removeItem(at: folder) }
                        throw error
                    }
                    return project
                }.value
                if currentURL != url { try await cleanupClosedProject() }
                // The new file is already saved. Do not save the old snapshot over it.
                await store.select(url: url, id: result.id)
                try show.replaceProject(result)
                StemAudioPlayback.shared.open(directory: url.deletingLastPathComponent())
                VideoPlayback.shared.open(directory: url.deletingLastPathComponent())
                VideoPlayback.teleprompter.open(directory: url.deletingLastPathComponent())
                #if os(macOS)
                TeleprompterRemote.shared.setDirectory(url.deletingLastPathComponent())
                #endif
                VideoPlayback.shared.update(show.snapshot)
                TrackRecording.shared.open(directory: url.deletingLastPathComponent(), project: show.snapshot.project.id)
                show.preparePlayback()
                currentURL = url; remember(url); ready = true; opened = UUID(); self.scan = nil; addTarget = nil
            } catch { self.error = error.localizedDescription }
        }
        #endif
    }
}

struct ProjectBrowserView: View {
    @ObservedObject var documents: ProjectDocuments
    var completed: () -> Void = {}
    @State private var creating = false
    @State private var opening = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let folders = documents.folderReview {
                FolderImportReview(folders: folders, cancel: { documents.folderReview = nil }, confirm: documents.confirmFolders)
            } else if let scan = documents.scan {
                Text("Review stems").font(.title3.bold())
                Text("\(scan.folders.count) song folders · \(scan.folders.reduce(0) { $0 + $1.files.count }) audio files").font(.caption)
                if !scan.suggestions.isEmpty {
                    Text("Repeated names were found that may identify providers. Select suggestions or type names to remove.").font(.caption).foregroundStyle(JarasTheme.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(scan.suggestions) { item in
                                Button {
                                    var terms = documents.removal.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                                    if let index = terms.firstIndex(of: item.text) { terms.remove(at: index) } else { terms.append(item.text) }
                                    documents.removal = terms.joined(separator: ", ")
                                } label: {
                                    HStack { Text(item.text); Spacer(); Text("\(item.count)×") }.padding(7).frame(maxWidth: .infinity).background(JarasTheme.panel).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(maxHeight: 120)
                }
                TextField("Names to remove, separated by commas", text: $documents.removal).textFieldStyle(.roundedBorder)
                Text("Original folders remain unchanged. Audio is copied beside the .jl project.").font(.caption2).foregroundStyle(JarasTheme.secondary)
                HStack { Button("Back") { documents.scan = nil }; Spacer(); Button("Create / Add") { documents.confirmImport() }.buttonStyle(StageButtonStyle(color: JarasTheme.green)) }
            } else {
                Text("Jaras Live").font(.title2.bold())
                HStack(spacing: 10) {
                    action("Create Project", icon: "plus.rectangle") { creating.toggle(); opening = false }
                    action("Add Project", icon: "folder.badge.plus") {
                        documents.addProject()
                    }
                    action("Open Project", icon: "folder") { opening = true; creating = false }
                }
                if creating {
                    HStack {
                        action("Add Stems", icon: "waveform") { documents.chooseStems(adding: false) }
                        action("Empty", icon: "doc") { documents.createEmpty() }
                    }
                }
                if opening {
                HStack { Text("Recent projects").font(.caption).foregroundStyle(JarasTheme.secondary); Spacer(); Button("Browse…") { documents.browse() } }
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(documents.recent, id: \.path) { url in
                            Button { documents.open(url) } label: {
                                HStack { VStack(alignment: .leading) { Text(url.deletingPathExtension().lastPathComponent).font(.body.bold()); Text(url.deletingLastPathComponent().path).font(.caption2).foregroundStyle(JarasTheme.secondary).lineLimit(1) }; Spacer(); Image(systemName: "chevron.right") }
                                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(JarasTheme.panel).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 170)
                }
            }
            if !documents.warnings.isEmpty { Text(documents.warnings.joined(separator: "\n")).font(.caption).foregroundStyle(JarasTheme.yellow).lineLimit(3).jarasHelp(documents.warnings.joined(separator: "\n")) }
            if !documents.error.isEmpty { Text(LocalizedStringKey(documents.error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if documents.busy { HStack { ProgressView().controlSize(.small); Text(LocalizedStringKey(documents.status)).font(.caption) } }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(JarasTheme.background).foregroundStyle(JarasTheme.text)
            .disabled(documents.busy || documents.show.isPlaying)
            .onChange(of: documents.opened) { _ in completed() }
            .onChange(of: documents.scan == nil) { done in if done && documents.ready { completed() } }
    }
    private func action(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(LocalizedStringKey(title), systemImage: icon).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, minHeight: 38).background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
}

#if os(macOS)
struct ProjectWindowSizing: NSViewRepresentable {
    let editor: Bool
    let documents: ProjectDocuments
    func makeNSView(context: Context) -> ProjectWindowAnchor { ProjectWindowAnchor() }
    func updateNSView(_ view: ProjectWindowAnchor, context: Context) { view.editor = editor; view.documents = documents; view.update() }
}
final class ProjectWindowAnchor: NSView {
    var editor = false
    weak var documents: ProjectDocuments?
    private var applied: NSSize?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); update() }
    func update() {
        guard let window else { return }
        if let documents { ProjectCloseGuard.shared.attach(window: window, documents: documents) }
        let reviewing = documents?.folderReview != nil
        let size = editor ? NSSize(width: 1360, height: 800) : reviewing ? NSSize(width: 840, height: 540) : NSSize(width: 600, height: 460)
        guard applied != size else { return }
        applied = size
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.minSize = self.editor ? NSSize(width: 1050, height: 650) : reviewing ? NSSize(width: 760, height: 460) : NSSize(width: 600, height: 460)
            window.setContentSize(size)
            window.center()
        }
    }
}
#endif
