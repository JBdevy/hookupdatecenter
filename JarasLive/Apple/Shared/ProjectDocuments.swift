import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import AVFoundation
#endif

@MainActor final class ProjectDocuments: ObservableObject {
    @Published var ready = false
    @Published var opened = UUID()
    @Published var currentURL: URL?
    @Published var recent: [URL] = []
    @Published var canCancelOpening = false
    private var openingTask: Task<Void, Never>?
    private var openingCancellation: ProjectOpeningCancellation?
    func cancelOpening() {
        guard canCancelOpening else { return }
        canCancelOpening = false; status = "Canceling…"
        openingCancellation?.cancel(); openingTask?.cancel()
    }
    func cancelOpeningAndWait() async -> Bool {
        guard let task = openingTask,
              canCancelOpening || openingCancellation?.cancelled == true else { return false }
        cancelOpening()
        // The opening task owns its cancellation cleanup and the busy state.
        await task.value
        return !busy
    }
    private func beginOpening(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true; error = ""; status = "Opening project…"; canCancelOpening = true
        openingCancellation = ProjectOpeningCancellation()
        openingTask = Task {
            defer { busy = false; canCancelOpening = false; openingTask = nil; openingCancellation = nil; status = "" }
            do { try await operation() }
            catch is CancellationError { missingAudioPrompt = nil }
            catch { if Task.isCancelled { missingAudioPrompt = nil } else { self.error = error.localizedDescription } }
        }
    }
    @Published var busy = false {
        didSet { if !busy { closeNotice = "" } }
    }
    @Published var closeNotice = ""
    @Published var status = ""
    @Published var error = ""
    @Published var folderReview: [URL]?
    @Published private(set) var folders: [URL] = []
    @Published private(set) var selectedFolders: [URL] = []
    @Published var showingOpenProjectAlert = false
    @Published var scan: StemScan?
    @Published var removal = ""
    @Published var warnings: [String] = []
    @Published var missingAudioPaths: Set<String> = []
    struct MissingAudioPrompt: Identifiable {
        let id = UUID()
        let project: Project
        let url: URL
        var paths: [String]
        var errors: [String] = []
    }
    @Published var missingAudioPrompt: MissingAudioPrompt?
    @Published var importingAudio = false
    @Published var audioImportError = ""
    @Published var migrationNotice = ""
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
        guard show.canExecute(), ready, !busy, !providers.isEmpty, let destination = currentURL,
              let arrangement = show.snapshot.project.songs.first(where: { $0.id == song }) else { return false }
        let projectID = show.snapshot.project.id
        if let track, !arrangement.tracks.contains(where: { $0.id == track }) {
            audioImportError = "The destination track no longer exists"; return false
        }
        let destinationKind = track.flatMap { id in arrangement.tracks.first { $0.id == id }?.kind }
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
                    for imported in prepared.tracks where imported.kind == .video || imported.kind.isTeleprompter {
                        guard show.snapshot.project.songs.first(where: { $0.id == song })?.tracks.contains(where: { $0.id == imported.id && $0.kind == imported.kind }) == true else {
                            throw ProjectError.invalid("The destination Video track no longer exists")
                        }
                    }
                    #if os(macOS)
                    var waveProject = show.snapshot.project
                    if let index = waveProject.songs.firstIndex(where: { $0.id == song }) {
                        for track in prepared.tracks {
                            if let existing = waveProject.songs[index].tracks.firstIndex(where: { $0.id == track.id }) {
                                waveProject.songs[index].tracks[existing].clips += track.clips
                            } else { waveProject.songs[index].tracks.append(track) }
                        }
                        await preloadTimelineWaveforms(waveProject, at: destination)
                    }
                    #endif
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
        if message == "Select media files, not folders." {
            return JarasLocalization.string("This item cannot be added. Select audio, video or image files, not folders.")
        }
        for (prefix, key) in [("Unsupported media file: ", "This item cannot be added. Select an audio, video or image file: %@"),
                              ("Empty media file: ", "Empty media file: %@")] {
            if message.hasPrefix(prefix) {
                return String(format: JarasLocalization.string(key), String(message.dropFirst(prefix.count)))
            }
        }
        return message
    }
    #if os(macOS)
    func pasteMedia(_ urls: [URL], track: UUID?) {
        guard show.canExecute(), ready, !busy, !urls.isEmpty,
              let song = show.current, pendingAudioDrop == nil else { return }
        let project = show.snapshot.project.id
        let position = show.snapshot.transport.editPosition ?? show.snapshot.transport.position
        busy = true; status = "Importing audio…"
        Task {
            busy = false; status = ""
            guard show.snapshot.project.id == project, show.current?.id == song.id else { return }
            let destination = track
            // Keep the drop layout/gap question, validation, project-local
            // media copies, waveform preparation and undo transaction.
            _ = importAudio(urls.map { NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier) },
                start: position, track: destination, song: song.id)
        }
    }
    #endif

    func chooseVideo(track: UUID) {
        #if os(macOS)
        guard let song = show.current else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie, .image]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        _ = importAudio(panel.urls.map { NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier) }, start: show.snapshot.transport.editPosition ?? show.snapshot.transport.position, track: track, song: song.id, layout: .sameTrack)
        #endif
    }
    @Published private(set) var adding = false
    private var appendDestination: (project: UUID, url: URL)?
    private let store: DocumentProjectStore
    let show: ShowController
    #if os(macOS)
    private var remoteProjectCatalog = DAWRemoteProjectCatalog()
    private var remoteProjectError = ""
    var remoteProjectBrowser: DAWRemoteState.ProjectBrowser {
        let recent = remoteProjectCatalog.update(self.recent, current: currentURL)
        let recording = TrackRecording.shared.recording || TrackRecording.shared.busy
        let busy = self.busy || show.saving
        let status = busy ? "Opening project…" : recording ? "Stop recording on the Mac to open a project." :
            show.isPlaying ? "Stop playback to open a project." : ""
        let error = !remoteProjectError.isEmpty ? remoteProjectError : missingAudioPrompt != nil ?
            "Resolve missing audio on the Mac to continue." : self.error.isEmpty ? "" :
            "Could not open the project. Check the Mac for details."
        return .init(recent: recent, busy: busy,
                     canOpen: !busy && !recording && !show.isPlaying && missingAudioPrompt == nil,
                     status: status, error: error)
    }
    func openRemoteProject(_ id: UUID) {
        remoteProjectError = ""
        guard remoteProjectBrowser.canOpen else { return }
        guard let url = remoteProjectCatalog.url(for: id) else {
            remoteProjectError = "This project is no longer in the Mac’s recent projects."
            return
        }
        guard url != currentURL?.standardizedFileURL else { return }
        // The normal document transition flushes unsaved changes before replacing
        // the project, and keeps the current project if saving or loading fails.
        open(url)
    }
    #endif
    init(store: DocumentProjectStore, show: ShowController, preview: Bool) {
        self.store = store; self.show = show; ready = preview
        recent = (UserDefaults.standard.stringArray(forKey: "jaras.recentProjects") ?? []).map { URL(fileURLWithPath: $0) }
        #if os(macOS)
        DAWRemoteHostBridge.documents = self
        #endif
    }
    private func remember(_ url: URL) {
        ProjectDocumentAppearance.apply(to: url)
        recent.removeAll { $0 == url }; recent.insert(url, at: 0); recent = Array(recent.prefix(20))
        UserDefaults.standard.set(recent.map(\.path), forKey: "jaras.recentProjects")
    }
    @Published var pendingDeletion: ProjectFolderDeletion?
    func requestDeletion(_ url: URL) {
        guard !busy, !show.isPlaying, !show.saving, !TrackRecording.shared.recording,
              !TrackRecording.shared.busy, !importingAudio else { return }
        error = ""
        if RecentProjectEntry.isMissing(url) {
            recent.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
            UserDefaults.standard.set(recent.map(\.path), forKey: "jaras.recentProjects")
            return
        }
        do { pendingDeletion = try ProjectFolderDeletion(document: url) }
        catch { self.error = error.localizedDescription }
    }
    func deleteProject(_ deletion: ProjectFolderDeletion) {
        guard pendingDeletion?.id == deletion.id, deletion.remainingSeconds == 0,
              !busy, !show.isPlaying, !show.saving, !TrackRecording.shared.recording,
              !TrackRecording.shared.busy, !importingAudio else { return }
        busy = true; error = ""; status = "Deleting project…"
        Task {
            let canExecute = show.canExecute
            show.canExecute = { false }
            defer { show.canExecute = canExecute; busy = false; status = "" }
            do {
                try deletion.validate()
                // Preserve a different open project before returning to startup.
                if ready, let currentURL, !deletion.contains(currentURL) { try await show.saveForClosing() }
                show.send(.stopAll)
                #if os(macOS)
                FXWindows.shared.closeAll()
                if TeleprompterWindow.shared.visible { TeleprompterWindow.shared.toggle(show: show) }
                if TeleprompterWindow.second.visible { TeleprompterWindow.second.toggle(show: show) }
                TeleprompterRemote.shared.setDirectory(nil)
                #endif
                VideoPlayback.shared.closeProject()
                VideoPlayback.teleprompter.closeProject()
                VideoPlayback.teleprompter2.closeProject()
                StemAudioPlayback.shared.prepareForClosing()
                TrackRecording.shared.closeProject()
                await store.deselect()
                try await Task.detached(priority: .userInitiated) { try deletion.remove() }.value
                recent.removeAll { deletion.contains($0) }
                UserDefaults.standard.set(recent.map(\.path), forKey: "jaras.recentProjects")
                try show.replaceProject(.empty(name: "Untitled"))
                currentURL = nil; ready = false; pendingDeletion = nil
                clearImportSelection()
                warnings = []; missingAudioPaths = []; missingAudioPrompt = nil
                migrationNotice = ""; pendingAudioDrop = nil
                opened = UUID()
            } catch {
                // Keep the session usable if saving, validation or deletion fails.
                if let url = currentURL {
                    await store.select(url: url, id: show.snapshot.project.id)
                    let directory = url.deletingLastPathComponent()
                    StemAudioPlayback.shared.open(directory: directory)
                    VideoPlayback.shared.open(directory: directory)
                    VideoPlayback.teleprompter.open(directory: directory)
                    VideoPlayback.teleprompter2.open(directory: directory)
                    TrackRecording.shared.open(directory: directory, project: show.snapshot.project.id)
                    #if os(macOS)
                    TeleprompterRemote.shared.setDirectory(directory)
                    #endif
                    show.preparePlayback()
                }
                self.error = error.localizedDescription
            }
        }
    }
    func rememberProjectMedia() async throws {
        guard ready, let currentURL else { return }
        let project = show.snapshot.project, known = show.knownMediaPaths
        try await Task.detached(priority: .utility) {
            try ProjectMediaCleanup.remember(project: project, document: currentURL, knownPaths: known)
        }.value
    }
    var canCleanTimelineMedia: Bool {
        ready && currentURL != nil && !busy && !show.isPlaying && !show.saving &&
        !TrackRecording.shared.recording && !TrackRecording.shared.busy && !importingAudio
    }
    func cleanTimelineMedia() async throws {
        guard canCleanTimelineMedia, let currentURL else {
            throw ProjectError.invalid("Stop playback, recording and imports before cleaning timeline files.")
        }
        busy = true
        let canExecute = show.canExecute
        show.canExecute = { false }
        defer { busy = false; show.canExecute = canExecute }
        try await show.saveForClosing()
        let project = show.snapshot.project, known = show.knownMediaPaths
        // Once deletion starts, undo cannot restore references to removed sources,
        // including if a later filesystem operation fails halfway through.
        show.discardClosedHistory()
        try await Task.detached(priority: .userInitiated) {
            try ProjectMediaCleanup.remember(project: project, document: currentURL, knownPaths: known)
            try ProjectMediaCleanup.removeDeletedFiles(project: project, document: currentURL, knownPaths: known)
        }.value
    }
    private func preloadTimelineWaveforms(_ project: Project, at url: URL) async {
        #if os(macOS)
        let directory = url.deletingLastPathComponent()
        let missing = await Task.detached(priority: .userInitiated) {
            Set(ProjectAudioRecovery.missingPaths(in: project, directory: directory))
        }.value
        let files = project.songs.flatMap(\.tracks).filter { $0.kind == .standard }.flatMap { track in
            track.clips.compactMap { clip -> URL? in
                guard !clip.isProjectionMedia, let file = clip.audioFile ?? track.audioFile, !missing.contains(file.path) else { return nil }
                return directory.appendingPathComponent(file.path)
            }
        }
        // Resolve movie audio before the workspace can start playback. A
        // render deadline must never wait for AVAssetReader container decoding.
        let movies = Set(project.songs.flatMap(\.tracks).flatMap(\.clips).compactMap { clip -> String? in
            guard clip.isProjectionMedia, !clip.isImage, let path = clip.audioFile?.path, !missing.contains(path) else { return nil }
            return path
        })
        let opening = openingCancellation
        if !movies.isEmpty {
            status = "Preparing audio…"
            await Task.detached(priority: .userInitiated) {
                for path in movies {
                    guard opening?.cancelled != true, !Task.isCancelled else { return }
                    _ = try? AudioFileRead.openMedia(directory.appendingPathComponent(path), cancelled: { opening?.cancelled == true })
                }
            }.value
        }
        status = "Preparing waveforms…"
        let cancellation = openingCancellation
        await TimelineAudioWaveform.shared.preload(files, cancelled: { cancellation?.cancelled == true }) { done, total in
            guard cancellation?.cancelled != true else { return }
            self.status = "Preparing waveforms… \(done)/\(total)"
        }
        #endif
    }
    private func activate(_ project: Project, at url: URL) async throws {
        var project = project
        for song in project.songs.indices {
            for track in project.songs[song].tracks.indices where project.songs[song].tracks[track].role.rawValue == "video" {
                project.songs[song].tracks[track].role = .other
            }
        }
        if let global = GlobalProjectTiming.load() { global.applyOnOpen(to: &project) }
        else if let song = project.songs.first { GlobalProjectTiming(song: song).save() }
        try project.validate()
        await preloadTimelineWaveforms(project, at: url)
        try Task.checkCancellation()
        canCancelOpening = false
        if ready && show.hasUnsavedChanges { try await show.saveForClosing() }
        if currentURL != url { try await rememberProjectMedia() }
        await store.select(url: url, id: project.id)
        try show.replaceProject(project)
        let missing = Set(ProjectAudioRecovery.missingPaths(in: project, directory: url.deletingLastPathComponent()))
        StemAudioPlayback.shared.open(directory: url.deletingLastPathComponent())
        StemAudioPlayback.shared.setMissingAudioPaths(missing)
        VideoPlayback.shared.open(directory: url.deletingLastPathComponent())
        VideoPlayback.teleprompter.open(directory: url.deletingLastPathComponent())
        VideoPlayback.teleprompter2.open(directory: url.deletingLastPathComponent())
        #if os(macOS)
        TeleprompterRemote.shared.setDirectory(url.deletingLastPathComponent())
        #endif
        VideoPlayback.shared.update(show.snapshot)
        TrackRecording.shared.open(directory: url.deletingLastPathComponent(), project: show.snapshot.project.id)
        show.preparePlayback()
        missingAudioPaths = missing
        currentURL = url; remember(url); ready = true; opened = UUID()
    }
    private func finishOpening(_ project: Project, at url: URL) async throws {
        status = "Preparing waveforms…"
        var enriched = try await ProjectOpeningWork.run {
            try StemProjectImporter.populateChannelOverviews(project, directory: url.deletingLastPathComponent())
        }
        for index in enriched.songs.indices { enriched.songs[index].ensureInitialTempoMarker() }
        try Task.checkCancellation()
        try await activate(enriched, at: url)
        if enriched != project { try await ProjectStore(url: url).save(enriched) }
    }
    func open(_ url: URL) {
        guard !busy, !show.isPlaying, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        #if os(macOS)
        if ["logicx", "rpp"].contains(url.pathExtension.lowercased()) { importDAW(url); return }
        #endif
        beginOpening {
            guard ["jl", "bkjl"].contains(url.pathExtension.lowercased()) else { throw ProjectError.invalid("Select a .jl or .bkjl project") }
            let url = try await ProjectOpeningWork.run {
                try url.pathExtension.lowercased() == "bkjl" ? ProjectBackups.restore(url) : url
            }
            guard let project = try await ProjectStore(url: url).load() else { throw ProjectError.invalid("Project not found") }
            try Task.checkCancellation()
            try project.validate()
            let missing = try await ProjectOpeningWork.run {
                ProjectAudioRecovery.missingPaths(in: project, directory: url.deletingLastPathComponent())
            }
            if !missing.isEmpty {
                self.missingAudioPrompt = MissingAudioPrompt(project: project, url: url, paths: missing)
                return
            }
            try await self.finishOpening(project, at: url)
        }
    }
    func searchMissingAudio(in folder: URL) {
        guard !busy, let prompt = missingAudioPrompt else { return }
        busy = true; status = "Searching for missing audio…"
        Task {
            defer { busy = false }
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ProjectAudioRecovery.restore(prompt.project, directory: prompt.url.deletingLastPathComponent(), searching: folder)
                }.value
                if result.remaining.isEmpty {
                    try await finishOpening(prompt.project, at: prompt.url)
                    missingAudioPrompt = nil
                } else {
                    missingAudioPrompt?.paths = result.remaining
                    missingAudioPrompt?.errors = result.errors
                }
            } catch {
                missingAudioPrompt?.paths = ProjectAudioRecovery.missingPaths(in: prompt.project, directory: prompt.url.deletingLastPathComponent())
                missingAudioPrompt?.errors = [error.localizedDescription]
            }
        }
    }
    func openWithMissingAudio() {
        guard !busy, let prompt = missingAudioPrompt else { return }
        beginOpening {
            try await self.finishOpening(prompt.project, at: prompt.url)
            self.missingAudioPrompt = nil
        }
    }
    func cancelMissingAudioOpen() {
        if canCancelOpening { cancelOpening() }
        else if !busy { missingAudioPrompt = nil }
    }
    #if os(macOS)
    func chooseMigration(_ fileExtension: String) {
        guard !busy, !show.isPlaying, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = fileExtension == "logicx"
            ? [UTType("com.apple.logicx.project") ?? .package, .package, .folder]
            : [UTType(filenameExtension: fileExtension) ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = fileExtension == "logicx"
        panel.treatsFilePackagesAsDirectories = false
        panel.title = JarasLocalization.string(fileExtension == "rpp" ? "Import REAPER project" : "Import Logic project")
        let validator = ProjectSourcePanelValidator(extensions: [fileExtension])
        panel.delegate = validator
        let response = withExtendedLifetime(validator) { panel.runModal() }
        if response == .OK, let source = panel.url { importDAW(source) }
    }
    private func importDAW(_ source: URL) {
        guard show.canExecute() else { return }
        let isReaper = source.pathExtension.lowercased() == "rpp"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "jl") ?? .data]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".jl"
        panel.title = JarasLocalization.string(isReaper ? "Import REAPER project" : "Import Logic project")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        let destination = selected.pathExtension.lowercased() == "jl" ? selected : selected.appendingPathExtension("jl")
        guard !destination.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/") else {
            error = "Save the CatLive project outside the Logic package."; return
        }
        do { try ProjectDirectoryPolicy.validate(destination) }
        catch { self.error = error.localizedDescription; return }
        busy = true; error = ""; warnings = []; migrationNotice = ""
        status = isReaper ? "Importing REAPER project…" : "Importing Logic project…"
        Task {
            defer { busy = false }
            do {
                let (result, teleprompter) = try await Task.detached(priority: .userInitiated) {
                    let result = try isReaper ? ReaperProjectImporter.read(source) : LogicProjectImporter.read(source)
                    try ProjectMigration.save(result, to: destination)
                    return (result, isReaper ? VSHookTeleprompterMigration.read(for: source) : nil)
                }.value
                if VSHookTeleprompterMigration.applyOnce(teleprompter) {
                    TeleprompterPreferences.shared.reload(); TeleprompterPreferences.second.reload()
                    TPNoticeController.shared.reload()
                }
                warnings = result.warnings.map { JarasLocalization.string($0) }
                let missing = ProjectAudioRecovery.missingPaths(in: result.project, directory: destination.deletingLastPathComponent())
                if !missing.isEmpty {
                    missingAudioPrompt = MissingAudioPrompt(project: result.project, url: destination, paths: missing)
                } else {
                    try await finishOpening(result.project, at: destination)
                    migrationNotice = warnings.joined(separator: "\n\n")
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    #endif
    func browse() {
        #if os(macOS)
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "jl") ?? .data, UTType(filenameExtension: "bkjl") ?? .data, UTType(filenameExtension: "logicx") ?? .package, UTType(filenameExtension: "rpp") ?? .data, .package, .folder]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        let validator = ProjectSourcePanelValidator(extensions: ["jl", "bkjl", "logicx", "rpp"])
        panel.delegate = validator
        let response = withExtendedLifetime(validator) { panel.runModal() }
        if response == .OK, let url = panel.url { open(url) }
        #endif
    }
    func addProject() {
        guard !busy, !show.isPlaying, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        guard ready, currentURL != nil else {
            clearImportSelection(); showingOpenProjectAlert = true; return
        }
        chooseStems(adding: true)
    }
    func chooseStems(adding: Bool) {
        guard !busy, !show.isPlaying, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        if adding {
            guard ready, currentURL != nil else {
                clearImportSelection(); showingOpenProjectAlert = true; return
            }
        }
        #if os(macOS)
        let destination = adding ? currentURL.map { (project: show.snapshot.project.id, url: $0) } : nil
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { cancelImport(); return }
        clearImportSelection()
        self.adding = adding; appendDestination = destination; error = ""; warnings = []
        let urls = panel.urls
        folders = urls
        if adding || urls.count > 1 { folderReview = urls }
        else { selectedFolders = urls; analyzeFolders(urls) }
        #endif
    }
    func confirmFolders(_ urls: [URL]) {
        guard let available = folderReview, !urls.isEmpty, urls.allSatisfy(available.contains), !busy else { return }
        selectedFolders = urls
        folderReview = nil
        analyzeFolders(urls)
    }
    func reviewFolderOrder() {
        guard !busy, !folders.isEmpty else { return }
        scan = nil; folderReview = folders
    }
    func cancelImport() {
        guard !busy else { return }
        clearImportSelection(); warnings = []; error = ""; status = ""; showingOpenProjectAlert = false
    }
    private func clearImportSelection() {
        scan = nil; folderReview = nil; folders = []; selectedFolders = []
        removal = ""; adding = false; appendDestination = nil
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
    func createEmpty() { finish(scan: nil, detectBPM: false) }
    func confirmImport(detectBPM: Bool) { guard let scan else { return }; finish(scan: scan, detectBPM: detectBPM) }
    private func finish(scan: StemScan?, detectBPM: Bool) {
        guard show.canExecute(), !busy, !show.isPlaying, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        #if os(macOS)
        let append = scan != nil && adding
        let url: URL
        if append {
            guard ready, let currentURL else { showingOpenProjectAlert = true; return }
            guard let destination = appendDestination, currentURL == destination.url,
                  show.snapshot.project.id == destination.project else {
                error = "The open project changed. Start Add Project again."; return
            }
            url = currentURL
        } else {
            let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "jl") ?? .data]
            panel.nameFieldStringValue = "Untitled.jl"; panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let selected = panel.url else { return }
            url = selected.pathExtension.lowercased() == "jl" ? selected : selected.appendingPathExtension("jl")
            guard !FileManager.default.fileExists(atPath: url.path) else { error = "A project already exists at this location. Choose another name."; return }
        }
        do { try ProjectDirectoryPolicy.validate(url) }
        catch { self.error = error.localizedDescription; return }
        let base = append ? show.snapshot.project : Project.empty(name: url.deletingPathExtension().lastPathComponent)
        let remove = removal
        busy = true; error = ""; status = "Copying audio and saving project…"
        Task {
            defer { busy = false }
            do {
                // Flush the previous document before replacing it or appending media.
                if ready && show.hasUnsavedChanges { try await show.flushProject() }
                let result = try await Task.detached(priority: .userInitiated) {
                    var project = try scan.map { try StemProjectImporter.build(scan: $0, remove: remove, base: base, destination: url, progress: { [weak self] current, total, name in
                        Task { @MainActor [weak self] in self?.status = "Importing \(current)/\(total): \(name)" }
                    }) } ?? base
                    var tempoWarnings: [String] = []
                    do {
                    if detectBPM, scan != nil, !project.songs.isEmpty {
                        Task { @MainActor [weak self] in self?.status = "Detecting BPM…" }
                        var song = project.songs[0]
                        let existingRegions = Set(base.songs.flatMap(\.parts).map(\.id))
                        let directory = url.deletingLastPathComponent()
                        for region in song.parts where !existingRegions.contains(region.id) && region.parentRegionID == nil {
                            try Task.checkCancellation()
                            let detection = try ClickTempoDetector.markersWithMeter(song: song, region: region) { file in
                                try TimelineAudioWaveform.clickTransients(directory.appendingPathComponent(file.path)).map {
                                    ClickTempoDetector.Transient(position: $0.position, peak: $0.peak, shape: $0.shape)
                                }
                            }
                            if detection.markers.isEmpty {
                                tempoWarnings.append("No stable Click tempo found for \(region.name).")
                            } else {
                                song.insertDetectedTempo(detection.markers)
                            }
                        }
                        project.songs[0] = song
                    }
                    try project.validate()
                    let data = try ProjectDocumentCodec.encode(project)
                    try ProjectDocumentCodec.writeEncoded(data, to: url, exclusive: !append)
                    return (project, tempoWarnings)
                    } catch {
                        let existing = Set(base.songs.flatMap(\.tracks).flatMap(\.clips).compactMap { $0.audioFile?.path })
                        let imported = project.songs.flatMap(\.tracks).flatMap(\.clips).compactMap { $0.audioFile?.path }.filter { !existing.contains($0) }
                        for folder in Set(imported.map { url.deletingLastPathComponent().appendingPathComponent($0).deletingLastPathComponent() }) { try? FileManager.default.removeItem(at: folder) }
                        throw error
                    }
                }.value
                if currentURL != url { try await rememberProjectMedia() }
                // The new file is already saved. Do not save the old snapshot over it.
                await store.select(url: url, id: result.0.id)
                await preloadTimelineWaveforms(result.0, at: url)
                try show.replaceProject(result.0)
                StemAudioPlayback.shared.open(directory: url.deletingLastPathComponent())
                VideoPlayback.shared.open(directory: url.deletingLastPathComponent())
                VideoPlayback.teleprompter.open(directory: url.deletingLastPathComponent())
                VideoPlayback.teleprompter2.open(directory: url.deletingLastPathComponent())
                #if os(macOS)
                TeleprompterRemote.shared.setDirectory(url.deletingLastPathComponent())
                #endif
                VideoPlayback.shared.update(show.snapshot)
                TrackRecording.shared.open(directory: url.deletingLastPathComponent(), project: show.snapshot.project.id)
                show.preparePlayback()
                currentURL = url; remember(url); ready = true; clearImportSelection(); opened = UUID()
                warnings += result.1
            } catch { self.error = error.localizedDescription }
        }
        #endif
    }
}

struct MissingAudioRecoveryView: View {
    @ObservedObject var documents: ProjectDocuments
    @State private var choosingFolder = false
    var body: some View {
        if let prompt = documents.missingAudioPrompt {
            VStack(alignment: .leading, spacing: 14) {
                Text("Missing audio files").font(.title2.bold())
                Text(String(format: JarasLocalization.string(prompt.paths.count == 1 ? "%d audio file is missing" : "%d audio files are missing"), prompt.paths.count))
                    .foregroundStyle(JarasTheme.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(prompt.paths, id: \.self) { path in
                            Text(path).font(.system(.caption, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8).background(JarasTheme.panel)
                                .jarasHelp(path)
                        }
                    }
                }.frame(minHeight: 100, maxHeight: 300)
                if !documents.warnings.isEmpty {
                    Text(documents.warnings.joined(separator: "\n"))
                        .font(.caption).foregroundStyle(JarasTheme.yellow).fixedSize(horizontal: false, vertical: true)
                }
                if !prompt.errors.isEmpty {
                    Text(prompt.errors.joined(separator: "\n")).font(.caption).foregroundStyle(.red)
                        .lineLimit(3)
                }
                if documents.busy { HStack { ProgressView(); Text(LocalizedStringKey(documents.status)) }.font(.caption) }
                HStack {
                    Button("Cancel") { documents.cancelMissingAudioOpen() }.keyboardShortcut(.cancelAction).disabled(documents.busy && !documents.canCancelOpening)
                    Spacer()
                    Button("Open anyway") { documents.openWithMissingAudio() }.disabled(documents.busy)
                    Button("Search") { choosingFolder = true }.disabled(documents.busy)
                        .buttonStyle(StageButtonStyle(color: JarasTheme.green))
                }
            }
            .padding(22).frame(minWidth: 500, minHeight: 310)
            .background(JarasTheme.background).foregroundStyle(JarasTheme.text)
            .interactiveDismissDisabled()
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let folder): documents.searchMissingAudio(in: folder)
                case .failure(let error): documents.missingAudioPrompt?.errors = [error.localizedDescription]
                }
            }
        }
    }
}

struct ProjectBrowserView: View {
    @ObservedObject var documents: ProjectDocuments
    var completed: () -> Void = {}
    @State private var creating = false
    @State private var opening = false
    @State private var recentSearch = ""
    private var filteredRecent: [URL] { documents.recent.filter { RecentProjectEntry.matches($0, query: recentSearch) } }
    @State private var askingForBPM = false
    #if os(iOS)
    @State private var showingRemote = false
    #endif
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
            if let folders = documents.folderReview {
                FolderImportReview(folders: folders, selectedFolders: documents.selectedFolders, appending: documents.adding,
                                   cancel: documents.cancelImport, confirm: documents.confirmFolders)
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
                HStack { Button("Back", action: documents.reviewFolderOrder); Spacer(); Button("Create / Add") { askingForBPM = true }.buttonStyle(StageButtonStyle(color: JarasTheme.green)).keyboardShortcut(.defaultAction) }
            } else {
                Text("CatLive").font(.title2.bold())
                #if os(iOS)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                    startupCard("Create Project", icon: "plus.rectangle", color: JarasTheme.green) { creating.toggle(); opening = false }
                    startupCard("Add Project", icon: "folder.badge.plus", color: JarasTheme.purple) { documents.addProject() }
                    startupCard("Recent Projects", icon: "folder", color: JarasTheme.purple) { opening = true; creating = false }
                    startupCard("Remote", icon: "network", color: JarasTheme.green) { showingRemote = true }
                }.padding(.vertical, 12)
                #else
                HStack(spacing: 10) {
                    action("Create Project", icon: "plus.rectangle") { creating.toggle(); opening = false }
                    action("Add Project", icon: "folder.badge.plus") {
                        documents.addProject()
                    }
                    action("Recent Projects", icon: "folder") { opening = true; creating = false }
                    #if os(iOS)
                    action("Remote", icon: "network") { showingRemote = true }
                    #endif
                }
                #endif
                if creating {
                    HStack {
                        action("Add Stems", icon: "waveform") { documents.chooseStems(adding: false) }
                        action("Empty", icon: "doc") { documents.createEmpty() }
                        #if os(macOS)
                        action("REAPER", icon: "waveform.path") { documents.chooseMigration("rpp") }
                        action("Logic", icon: "pianokeys") { documents.chooseMigration("logicx") }
                        #endif
                    }
                }
                if opening {
                HStack { Text("Recent projects").font(.caption).foregroundStyle(JarasTheme.secondary); Spacer(); Button("Browse…") { documents.browse() } }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(JarasTheme.secondary)
                    TextField("Search recent projects", text: $recentSearch).textFieldStyle(.plain)
                    if !recentSearch.isEmpty {
                        Button { recentSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }.padding(9).background(JarasTheme.display).cornerRadius(6)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(filteredRecent, id: \.path) { url in
                            Button { documents.open(url) } label: {
                                HStack { VStack(alignment: .leading) { Text(url.deletingPathExtension().lastPathComponent).font(.body.bold()); Text(url.deletingLastPathComponent().path).font(.caption2).foregroundStyle(JarasTheme.secondary).lineLimit(1) }; Spacer(); Image(systemName: "chevron.right") }
                                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(JarasTheme.panel).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .contextMenu {
                                    Button {} label: { Label("Export to app", systemImage: "square.and.arrow.up") }.disabled(true)
                                    Button(role: .destructive) { documents.requestDeletion(url) } label: {
                                        Label(RecentProjectEntry.isMissing(url) ? "Remove from recents" : "Delete project", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }.frame(maxHeight: 170)
                if filteredRecent.isEmpty { Text("No recent projects found.").font(.caption).foregroundStyle(JarasTheme.secondary) }
                }
            }
            }.disabled(documents.busy || documents.show.isPlaying)
            if !documents.warnings.isEmpty { Text(documents.warnings.joined(separator: "\n")).font(.caption).foregroundStyle(JarasTheme.yellow).lineLimit(3).jarasHelp(documents.warnings.joined(separator: "\n")) }
            if !documents.error.isEmpty { Text(LocalizedStringKey(documents.error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if documents.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(LocalizedStringKey(documents.status)).font(.caption)
                    Spacer()
                    if documents.canCancelOpening {
                        Button("Cancel") { documents.cancelOpening() }.keyboardShortcut(.cancelAction)
                    }
                }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(JarasTheme.background).foregroundStyle(JarasTheme.text)
            .onChange(of: documents.opened) { _ in
                if !documents.ready { opening = false; creating = false }
                completed()
            }
            .sheet(item: $documents.pendingDeletion) { deletion in
                ProjectDeletionConfirmation(documents: documents, deletion: deletion)
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showingRemote) { DAWRemoteClientView() }
            #endif
            .alert("Open a project first", isPresented: $documents.showingOpenProjectAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Open a project before using Add Project.")
            }
            .confirmationDialog("Detect BPM for each song?", isPresented: $askingForBPM, titleVisibility: .visible) {
                Button("Yes") { documents.confirmImport(detectBPM: true) }
                Button("No") { documents.confirmImport(detectBPM: false) }
            }
    }
    private func action(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(LocalizedStringKey(title), systemImage: icon).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, minHeight: 38).background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
    #if os(iOS)
    private func startupCard(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: icon).font(.system(size: 30, weight: .medium)).foregroundStyle(color)
                HStack {
                    Text(LocalizedStringKey(title)).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(JarasTheme.secondary)
                }
            }.padding(20).frame(maxWidth: .infinity, minHeight: 146, alignment: .leading)
                .background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.3)))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
    #endif
}

private struct ProjectDeletionConfirmation: View {
    @ObservedObject var documents: ProjectDocuments
    let deletion: ProjectFolderDeletion
    @State private var remaining = 3
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Delete project", systemImage: "trash").font(.title3.bold()).foregroundStyle(.red)
            Text(verbatim: deletion.document.deletingPathExtension().lastPathComponent).font(.headline)
            if deletion.deletesDirectory {
                Text("The entire project folder, including audio and backups, will be permanently deleted. This cannot be undone.").font(.body)
            } else {
                Text("This project is in a shared folder. Only the selected project file will be permanently deleted and removed from recents. The folder, other projects, audio and backups will be kept. This cannot be undone.").font(.body)
            }
            Text(verbatim: deletion.target.path).font(.caption).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(JarasTheme.display).cornerRadius(5)
            if !documents.error.isEmpty { Text(LocalizedStringKey(documents.error)).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { documents.pendingDeletion = nil }.keyboardShortcut(.cancelAction).disabled(documents.busy)
                Spacer()
                if documents.busy { ProgressView().controlSize(.small) }
                Button(role: .destructive) { documents.deleteProject(deletion) } label: {
                    if remaining > 0 { Text("Delete in \(remaining)s") } else { Text("Delete project") }
                }.buttonStyle(StageButtonStyle(color: .red)).disabled(remaining > 0 || documents.busy)
            }
        }.padding(24).frame(width: 460).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .interactiveDismissDisabled(documents.busy)
            .task {
                remaining = deletion.remainingSeconds
                while remaining > 0, !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    remaining = deletion.remainingSeconds
                }
            }
    }
}

#if os(macOS)
/// Keep project controls in AppKit's titlebar without extending the timeline
/// hosting view beneath it. Only this small host measures its content.
struct ProjectTitlebarContent<Content: View>: NSViewRepresentable {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    func makeNSView(context: Context) -> ProjectTitlebarAnchor<Content> { ProjectTitlebarAnchor(content: content) }
    func updateNSView(_ view: ProjectTitlebarAnchor<Content>, context: Context) { view.update(content) }
    static func dismantleNSView(_ view: ProjectTitlebarAnchor<Content>, coordinator: ()) { view.detach() }
}

private final class ProjectTitlebarAccessory: NSTitlebarAccessoryViewController {
    var originalTitleVisibility: NSWindow.TitleVisibility = .visible
    var interactive = false
    static func containsControl(at point: NSPoint, in window: NSWindow) -> Bool {
        window.titlebarAccessoryViewControllers.contains { controller in
            guard let accessory = controller as? ProjectTitlebarAccessory, accessory.interactive,
                  !accessory.view.isHiddenOrHasHiddenAncestor else { return false }
            return accessory.view.bounds.insetBy(dx: 8, dy: 0).contains(accessory.view.convert(point, from: nil))
        }
    }
}

private struct ProjectTitlebarHostedContent<Content: View>: View {
    let content: Content
    var body: some View { content.padding(.horizontal, 8).frame(height: 22).clipped() }
}

private final class ProjectTitlebarHostingView<Content: View>: NSHostingView<Content> {
    var widthChanged: ((CGFloat) -> Void)?
    private var publishedWidth: CGFloat = -1
    private var measurementPending = false
    override func layout() { super.layout(); measureWidth() }
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        measureWidth()
    }
    private func measureWidth() {
        guard widthChanged != nil, !measurementPending else { return }
        measurementPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurementPending = false
            let width = self.intrinsicContentSize.width
            guard width.isFinite, width > 0, abs(width - self.publishedWidth) > 0.5 else { return }
            self.publishedWidth = width
            self.widthChanged?(width)
        }
    }
}

private final class ProjectTitlebarVersionView: NSView {
    static let text = "CatLive Version 1.00"
    private let label = NSTextField(labelWithString: text)
    var preferredWidth: CGFloat { ceil(label.intrinsicContentSize.width) + 20 }
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 160, height: 22))
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.alignment = .right
        label.lineBreakMode = .byClipping
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(Self.text)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let height = min(bounds.height, ceil(label.intrinsicContentSize.height))
        label.frame = NSRect(x: 6, y: floor((bounds.height - height) / 2), width: max(0, bounds.width - 16), height: height)
    }
    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class ProjectTitlebarAnchor<Content: View>: NSView {
    private let leading = ProjectTitlebarAccessory()
    private let trailing = ProjectTitlebarAccessory()
    private let host: ProjectTitlebarHostingView<ProjectTitlebarHostedContent<Content>>
    private let version = ProjectTitlebarVersionView()
    private weak var mountedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var preferredWidth: CGFloat = 500
    init(content: Content) {
        host = ProjectTitlebarHostingView(rootView: ProjectTitlebarHostedContent(content: content))
        super.init(frame: .zero)
        if #available(macOS 13, *) { host.sizingOptions = [.intrinsicContentSize] }
        host.frame = NSRect(x: 0, y: 0, width: preferredWidth, height: 22)
        host.widthChanged = { [weak self] width in self?.preferredWidth = width; self?.updateWidths() }
        leading.layoutAttribute = .left; leading.view = host; leading.interactive = true
        trailing.layoutAttribute = .right; trailing.view = version
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    func update(_ content: Content) {
        host.rootView = ProjectTitlebarHostedContent(content: content)
        attach()
    }
    private func attach() {
        guard mountedWindow !== window else { return }
        detach()
        guard let window else { return }
        mountedWindow = window
        // SwiftUI can briefly retain the previous background during a root
        // transition. Replace its accessories without losing the original title.
        let previous = window.titlebarAccessoryViewControllers.compactMap { $0 as? ProjectTitlebarAccessory }
        let original = previous.first?.originalTitleVisibility ?? window.titleVisibility
        for index in window.titlebarAccessoryViewControllers.indices.reversed() {
            if window.titlebarAccessoryViewControllers[index] is ProjectTitlebarAccessory { window.removeTitlebarAccessoryViewController(at: index) }
        }
        leading.originalTitleVisibility = original; trailing.originalTitleVisibility = original
        window.titleVisibility = .hidden
        updateWidths()
        window.addTitlebarAccessoryViewController(leading)
        window.addTitlebarAccessoryViewController(trailing)
        observers = [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, .catliveTrialTitleChanged].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.updateWidths() }
        }
    }
    private func updateWidths() {
        guard let window = mountedWindow else { return }
        let versionWidth = version.preferredWidth
        let controlsRight = window.standardWindowButton(.zoomButton).map { $0.convert($0.bounds, to: nil).maxX } ?? 80
        let available = max(0, window.frame.width - controlsRight - versionWidth - 60)
        let licenseLabel = window.standardWindowButton(.closeButton)?.superview?.subviews.first { $0.identifier?.rawValue == "catlive.trialTitle" && !$0.isHidden }
        let leadingAvailable = licenseLabel.map { min(available, $0.frame.minX - 15 - controlsRight) } ?? available
        let width = min(650, max(0, min(preferredWidth, leadingAvailable)))
        if abs(host.frame.width - width) > 0.5 { host.setFrameSize(NSSize(width: width, height: host.frame.height)) }
        if abs(version.frame.width - versionWidth) > 0.5 { version.setFrameSize(NSSize(width: versionWidth, height: version.frame.height)) }
    }
    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        guard let window = mountedWindow else { return }
        mountedWindow = nil
        var removed = false
        for index in window.titlebarAccessoryViewControllers.indices.reversed() {
            let accessory = window.titlebarAccessoryViewControllers[index]
            if accessory === leading || accessory === trailing { window.removeTitlebarAccessoryViewController(at: index); removed = true }
        }
        if removed, !window.titlebarAccessoryViewControllers.contains(where: { $0 is ProjectTitlebarAccessory }) {
            window.titleVisibility = leading.originalTitleVisibility
        }
    }
}

struct ProjectWindowSizing: NSViewRepresentable {
    let editor: Bool
    let documents: ProjectDocuments
    func makeNSView(context: Context) -> ProjectWindowAnchor { ProjectWindowAnchor() }
    func updateNSView(_ view: ProjectWindowAnchor, context: Context) { view.editor = editor; view.documents = documents; view.update() }
}
final class ProjectWindowAnchor: NSView {
    static let editorFrameSize = NSSize(width: 1440, height: 791)
    static func configureChrome(of window: NSWindow) {
        // The interface already stays below the native titlebar. Extending its
        // host underneath it makes AppKit walk every control's drag-prevention
        // region whenever a sidebar changes width.
        window.backgroundColor = NSColor(JarasTheme.titlebar)
        guard window.styleMask.contains(.fullSizeContentView) else { return }
        let frame = window.frame
        window.styleMask.remove(.fullSizeContentView)
        window.setFrame(frame, display: false)
    }
    var editor = false
    weak var documents: ProjectDocuments?
    private var applied: NSSize?
    private weak var configuredWindow: NSWindow?
    private weak var configuredDocuments: ProjectDocuments?
    private var placementObservers: [NSObjectProtocol] = []
    private var titlebarMonitor: Any?
    private var titlebarRestoreFrame: NSRect?
    private var remembersPlacement = false
    private static let placementKey = "jaras.editorWindowFrame"
    private func rememberPlacement() {
        guard remembersPlacement, let window, !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.placementKey)
    }
    deinit {
        placementObservers.forEach(NotificationCenter.default.removeObserver)
        if let titlebarMonitor { NSEvent.removeMonitor(titlebarMonitor) }
    }
    private func observeTitlebar(_ window: NSWindow) {
        if let titlebarMonitor { NSEvent.removeMonitor(titlebarMonitor) }
        titlebarMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self, weak window] event in
            guard let self, let window, self.editor, event.window === window, event.clickCount == 2,
                  !window.styleMask.contains(.fullScreen), window.attachedSheet == nil,
                  event.locationInWindow.y > window.contentLayoutRect.maxY else { return event }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(kind), button.bounds.contains(button.convert(event.locationInWindow, from: nil)) { return event }
            }
            if ProjectTitlebarAccessory.containsControl(at: event.locationInWindow, in: window) { return event }
            if event.type == .leftMouseDown, let screen = window.screen {
                let available = screen.visibleFrame
                let maximized = abs(window.frame.minX - available.minX) < 2 && abs(window.frame.minY - available.minY) < 2 && abs(window.frame.width - available.width) < 2 && abs(window.frame.height - available.height) < 2
                let destination: NSRect
                if maximized {
                    var restored = self.titlebarRestoreFrame ?? NSRect(origin: available.origin, size: Self.editorFrameSize)
                    restored.size.width = min(available.width, max(window.minSize.width, restored.width))
                    restored.size.height = min(available.height, max(window.minSize.height, restored.height))
                    restored.origin.x = min(max(restored.minX, available.minX), available.maxX - restored.width)
                    restored.origin.y = min(max(restored.minY, available.minY), available.maxY - restored.height)
                    destination = restored
                } else {
                    self.titlebarRestoreFrame = window.frame
                    destination = available
                }
                // One layout at the destination, instead of re-laying out the
                // timeline through every intermediate native zoom-animation size.
                window.setFrame(destination, display: true, animate: false)
            }
            return nil
        }
    }
    private func observePlacement(_ window: NSWindow) {
        placementObservers.forEach(NotificationCenter.default.removeObserver)
        placementObservers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.rememberPlacement() }
        }
    }
    private static func restoredFrame(fallback: NSRect) -> NSRect {
        guard let saved = UserDefaults.standard.string(forKey: placementKey) else { return fallback }
        var frame = NSRectFromString(saved)
        guard frame.width >= 1050, frame.height >= 650, frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite else { return fallback }
        let screen = NSScreen.screens.max { a, b in
            let ar = a.visibleFrame.intersection(frame), br = b.visibleFrame.intersection(frame)
            return (ar.isNull ? 0 : ar.width * ar.height) < (br.isNull ? 0 : br.width * br.height)
        }
        let visible = screen.flatMap { $0.visibleFrame.intersects(frame) ? $0.visibleFrame : nil } ?? NSScreen.main?.visibleFrame ?? fallback
        frame.size.width = min(max(1408, frame.width), visible.width); frame.size.height = min(max(682, frame.height), visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); update() }
    func update() {
        guard let window else { return }
        if let documents, configuredWindow !== window || configuredDocuments !== documents {
            ProjectCloseGuard.shared.attach(window: window, documents: documents)
            configuredDocuments = documents
        }
        // AppKit owns the size and placement of the native window controls.
        if configuredWindow !== window {
            Self.configureChrome(of: window)
            applied = nil
            configuredWindow = window
            observePlacement(window)
            observeTitlebar(window)
        }
        let reviewing = documents?.folderReview != nil
        let size = editor ? Self.editorFrameSize : reviewing ? NSSize(width: 840, height: 540) : NSSize(width: 600, height: 460)
        guard applied != size else { return }
        rememberPlacement()
        remembersPlacement = false
        applied = size
        let isEditor = editor
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.editor == isEditor else { return }
            window.minSize = isEditor ? NSSize(width: 1408, height: 682) : reviewing ? NSSize(width: 760, height: 460) : NSSize(width: 600, height: 460)
            if isEditor {
                let available = window.screen?.visibleFrame.size ?? size
                let frameSize = NSSize(width: min(size.width, available.width), height: min(size.height, available.height))
                window.setFrame(Self.restoredFrame(fallback: NSRect(origin: window.frame.origin, size: frameSize)), display: true)
                self.remembersPlacement = true
                self.rememberPlacement()
            } else {
                // These sizes described the full window with the previous
                // full-size content host; keep that same outer geometry.
                window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
            }
            if !isEditor { window.center() }
        }
    }
}
#endif

#if os(macOS)
/// Some Logic bundles arrive as ordinary directories (ZIP/external disks).
/// Let AppKit select either representation, validating the actual project suffix.
private final class ProjectSourcePanelValidator: NSObject, NSOpenSavePanelDelegate {
    let extensions: Set<String>
    init(extensions: Set<String>) { self.extensions = extensions }
    func panel(_ sender: Any, validate url: URL) throws {
        guard extensions.contains(url.pathExtension.lowercased()) else {
            throw ProjectError.invalid("Selecione um projeto " + extensions.sorted().map { "." + $0 }.joined(separator: ", ") + ".")
        }
    }
}
#endif

#if os(macOS)
/// Own only a token; actual copied items remain in ShowController. A new Finder
/// copy replaces this token so a stale internal selection cannot win Cmd+V.
@MainActor final class GridMediaClipboard {
    static let shared = GridMediaClipboard()
    enum Source: Equatable { case items, files([URL]), none }
    private let pasteboard: NSPasteboard
    private let itemType = NSPasteboard.PasteboardType("com.catlive.grid-items")
    private var token: String?
    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    func didCopyItems() {
        let value = UUID().uuidString
        pasteboard.clearContents()
        token = pasteboard.setString(value, forType: itemType) ? value : nil
    }
    func source() -> Source {
        if let token, pasteboard.string(forType: itemType) == token { return .items }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return urls.isEmpty ? .none : .files(urls)
    }
    nonisolated static func containsVisualMedia(_ urls: [URL]) -> Bool {
        urls.contains { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .image) == true { return true }
            guard type?.conforms(to: .movie) == true else { return false }
            // Missing files still go through the importer's normal error path.
            guard FileManager.default.fileExists(atPath: url.path) else { return true }
            return !AVURLAsset(url: url).tracks(withMediaType: .video).isEmpty
        }
    }
}
#endif
