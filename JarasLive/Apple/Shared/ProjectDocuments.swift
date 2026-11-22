import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
#if os(macOS)
import AppKit
import AudioToolbox
#endif

enum PortableProjectImportPrompt: String, Identifiable {
    case file, destination
    var id: String { rawValue }
    var title: String { self == .file ? "Choose a CatLive project" : "Choose a folder for the imported project" }
    var message: String {
        self == .file
            ? "Select the .ziplive file to open. Next, you will choose where to save the extracted project."
            : "Select a folder where CatLive will extract and save the project and its media. It will open as a normal project, independent of the .ziplive file."
    }
    var action: String { self == .file ? "Choose file" : "Choose folder" }
}

struct ProjectDeletionPrompt: Identifiable {
    let id = UUID()
    let document: URL
    let availableAt = ProcessInfo.processInfo.systemUptime + 3
    var plan: ProjectFolderDeletion?
    var remainingSeconds: Int { max(0, Int(ceil(availableAt - ProcessInfo.processInfo.systemUptime))) }
}

extension UTType {
    static let catLiveLyrics = UTType(exportedAs: "com.hookdeveloper.catlive.jllyrics", conformingTo: .json)
}

@MainActor final class ProjectDocuments: ObservableObject {
    let multitrack = MultitrackPresentation()
    func dropAtNativeGrid(_ providers: [NSItemProvider], position: Double, track: UUID?) -> Bool {
        guard let song = show.current else { return false }
        return importAudio(providers, start: position, track: track, song: song.id, layout: .separateTracks)
    }
    private func importLyrics(_ providers: [NSItemProvider], at position: Double, song: UUID, project: UUID) {
        busy = true
        audioImportError = ""
        Task {
            defer { busy = false }
            do {
                var lyrics = [JLLyricsDocument]()
                for provider in providers {
                    let data: Data = try await withCheckedThrowingContinuation { result in
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.catLiveLyrics.identifier) { data, error in
                            if let data { result.resume(returning: data) }
                            else { result.resume(throwing: error ?? ProjectError.invalid("Invalid .jllyrics file.")) }
                        }
                    }
                    let document = try await Task.detached(priority: .utility) {
                        try JSONDecoder().decode(JLLyricsDocument.self, from: data)
                    }.value
                    lyrics.append(document)
                }
                try show.insertLyrics(lyrics, at: position, song: song, project: project)
            } catch { audioImportError = formattedImportError(error) }
        }
    }

    func openMultitrackExport(clicked: UUID, selection: Set<UUID>) {
        guard multitrack.request == nil, let song = show.current, let region = song.parts.first(where: { $0.id == clicked }),
              region.parentRegionID == nil, let directory = currentURL?.deletingLastPathComponent() else { return }
        #if os(macOS)
        let tabs = DesktopProjectTabs.shared.projects
        #else
        let tabs = NativeProjectTabs.shared.projects
        #endif
        let active = tabs.first(where: { $0.documents === self })?.remoteProjectTabID ?? UUID()
        let selected: Set<UUID> = selection.contains(clicked) ? selection : [clicked]
        let current = MultitrackExportProject(tab: active, project: show.snapshot.project, song: song,
            mediaDirectory: directory, selection: selected)
        var configs = tabs.compactMap { tab -> MultitrackExportProject? in
            if tab.documents === self { return current }
            guard let song = tab.show.current, let directory = tab.documents.currentURL?.deletingLastPathComponent() else { return nil }
            return MultitrackExportProject(tab: tab.remoteProjectTabID, project: tab.show.snapshot.project, song: song,
                mediaDirectory: directory, selection: [])
        }
        if !configs.contains(where: { $0.id == active }) { configs.append(current) }
        multitrack.exporting = false
        multitrack.request = MultitrackExportRequest(projects: configs, active: active)
    }
    var projectAudio: StemAudioPlayback = .shared
    var additionalProtectedMediaURLs: () -> Set<URL> = { [] }
    var activateExistingProjectTab: ((URL) -> Bool)?
    var openInNewProjectTab: ((URL) -> Void)?
    var openProjectTabAndWait: ((URL) async throws -> Void)?
    #if os(macOS)
    var openRemoteInNewProjectTab: ((URL, UUID) -> Void)?
    var canChangeProject: () -> Bool = { true }
    #endif
    var navigateProjectTab: ((Int) -> Void)?
    private var temporarySession: TemporaryProjectSession?
    var isTemporary: Bool { currentURL.map { temporarySession?.contains($0) == true } ?? false }
    @Published var projectTabCount = 1
    @Published var projectTabIndex = 0

    #if os(iOS)
    enum NativePicker: String, Identifiable { case project, projectFile, projectFolder, reaper, logic, package, packageDestination, stems, trackAudio, trackMedia, storage, temporaryDestination; var id: String { rawValue } }
    @Published var nativePicker: NativePicker?
    @Published var nativePackagePrompt: PortableProjectImportPrompt?
    @Published private(set) var nativeStorageDirectory: URL?
    @Published private(set) var nativeStorageNeedsAccess = false
    private static let nativeStorageBookmarksKey = "jaras.nativeStorageBookmarks"
    private var restoredNativeStorageBookmarks: [Data] = []
    private var nativeStorageScopes: [URL] = []
    private var afterNativeStorage: (() -> Void)?
    private var nativePackageScope: URL?
    private var nativePendingPackage: URL?
    private var nativePendingProject: URL?
    private var nativeProjectScope: URL?
    var nativePickerDirectory: URL? { nativePendingProject?.deletingLastPathComponent() }
    private func cancelNativeProjectOpen() {
        nativePendingProject = nil
        nativeProjectScope?.stopAccessingSecurityScopedResource(); nativeProjectScope = nil
    }
    private func receiveNativeProject(_ url: URL) {
        if ["rpp", "logicx"].contains(url.pathExtension.lowercased()) { importNativeDAW(url); return }
        if ["ziplive", "zip"].contains(url.pathExtension.lowercased()) { importPortablePackage(url); return }
        guard ["jl", "bkjl"].contains(url.pathExtension.lowercased()) else {
            error = "Choose a .jl, .bkjl or .ziplive project."; return
        }
        guard !busy, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        cancelNativeProjectOpen()
        let container = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if NativeStemFolderBrowser.contains(url, in: container) ||
            nativeStorageScopes.contains(where: { NativeStemFolderBrowser.contains(url, in: $0) }) {
            open(url); return
        }
        // Open in place using the selected document's parent. Retain the
        // document grant for providers that expose the enclosing project folder.
        nativePendingProject = url
        if url.startAccessingSecurityScopedResource() { nativeProjectScope = url }
        let root = url.deletingLastPathComponent()
        if root.startAccessingSecurityScopedResource() { nativeStorageScopes.append(root) }
        open(url)
    }
    func chooseMigration(_ fileExtension: String) {
        guard !busy, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        nativePicker = fileExtension == "rpp" ? .reaper : .logic
    }
    private func importNativeDAW(_ source: URL, folderAuthorized: Bool = false) {
        guard show.canControl(), !busy, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        let isReaper = source.pathExtension.lowercased() == "rpp"
        let library = nativeStorageDirectory ?? Self.nativeProjectsDirectory
        let selected = library.appendingPathComponent(source.deletingPathExtension().lastPathComponent).appendingPathExtension("jl")
        let destination = ProjectMigration.isolatedDestination(for: selected)
        let warningBundle = JarasLocalization.bundle()
        let root = source.deletingLastPathComponent()
        let sourceAccess = source.startAccessingSecurityScopedResource()
        let rootAccess = root.startAccessingSecurityScopedResource()
        if isReaper, !folderAuthorized, !rootAccess,
           (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) == nil {
            cancelNativeProjectOpen()
            nativePendingProject = source
            if sourceAccess { nativeProjectScope = source }
            nativePicker = .projectFolder
            return
        }
        busy = true; error = ""; warnings = []; migrationNotice = ""
        status = isReaper ? "Importing REAPER project…" : "Importing Logic project…"
        Task {
            defer {
                if rootAccess { root.stopAccessingSecurityScopedResource() }
                if sourceAccess { source.stopAccessingSecurityScopedResource() }
                busy = false
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let localize: (String) -> String = { warningBundle.localizedString(forKey: $0, value: $0, table: nil) }
                    let result = try isReaper
                        ? ReaperProjectImporter.read(source, localizeWarning: localize, includePlugins: false)
                        : LogicProjectImporter.read(source, localizeWarning: localize)
                    try ProjectMigration.save(result, to: destination)
                    return result
                }.value
                warnings = result.warnings.map { JarasLocalization.string($0) }
                let missing = ProjectAudioRecovery.missingPaths(in: result.project, directory: destination.deletingLastPathComponent())
                if missing.isEmpty {
                    try await finishOpening(result.project, at: destination)
                    migrationNotice = warnings.joined(separator: "\n\n")
                } else {
                    missingAudioPrompt = MissingAudioPrompt(project: result.project, url: destination, paths: missing, isDAWImport: true)
                }
            } catch { self.error = ProjectMigration.errorDescription(error, localize: { JarasLocalization.string($0) }) }
        }
    }
    private func receiveNativeProjectFolder(_ root: URL) {
        guard let project = nativePendingProject else { return }
        defer { cancelNativeProjectOpen() }
        guard NativeStemFolderBrowser.contains(project, in: root) else {
            error = "Choose the folder containing the selected project and its media."; return
        }
        guard root.startAccessingSecurityScopedResource() else {
            error = "Could not access the selected folder."; return
        }
        do {
            let bookmark = try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            var bookmarks = UserDefaults.standard.array(forKey: "jaras.nativeImportedProjectBookmarks") as? [Data] ?? []
            bookmarks.removeAll { (try? Self.resolveNativeImportBookmark($0).standardizedFileURL) == root.standardizedFileURL }
            bookmarks.append(bookmark)
            UserDefaults.standard.set(bookmarks, forKey: "jaras.nativeImportedProjectBookmarks")
            if nativeStorageScopes.contains(where: { $0.standardizedFileURL == root.standardizedFileURL }) {
                root.stopAccessingSecurityScopedResource()
            } else { nativeStorageScopes.append(root) }
            if project.pathExtension.lowercased() == "rpp" { importNativeDAW(project, folderAuthorized: true) }
            else { open(project) }
        } catch { root.stopAccessingSecurityScopedResource(); self.error = error.localizedDescription }
    }
    func continueNativePackageImport(_ prompt: PortableProjectImportPrompt) {
        guard nativePackagePrompt == prompt else { return }
        nativePackagePrompt = nil
        guard !busy, !TrackRecording.shared.recording, !TrackRecording.shared.busy else {
            cancelNativePackageImport(); return
        }
        if prompt == .file { nativePicker = .package }
        else if nativePendingPackage != nil { nativePicker = .packageDestination }
    }
    func cancelNativePackageImport() {
        nativePackagePrompt = nil; nativePendingPackage = nil
        nativePackageScope?.stopAccessingSecurityScopedResource(); nativePackageScope = nil
    }
    func chooseNativeStorage() {
        guard !busy else { return }
        nativePicker = .storage
    }
    private func restoreNativeImportedFolders() {
        // Imported projects can live in individually chosen folders without
        // changing the default project folder.
        let container = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        for data in UserDefaults.standard.array(forKey: "jaras.nativeImportedProjectBookmarks") as? [Data] ?? [] {
            if let root = try? Self.resolveNativeImportBookmark(data), root.startAccessingSecurityScopedResource() {
                if (try? NativeProjectFolderStorage.externalRoot(root, container: container)) != nil {
                    retainNativeStorageScope(root)
                } else { root.stopAccessingSecurityScopedResource() }
            }
        }
    }
    func refreshNativeStorage() {
        let defaults = UserDefaults.standard
        let bookmarks = defaults.array(forKey: Self.nativeStorageBookmarksKey) as? [Data] ?? []
        guard bookmarks != restoredNativeStorageBookmarks else { return }
        let container = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        var activeDirectory: URL?
        var seen = Set<URL>()
        var refreshed: [Data] = []
        for (index, data) in bookmarks.enumerated() {
            var stale = false
            guard let selected = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
                  selected.startAccessingSecurityScopedResource() else { refreshed.append(data); continue }
            do {
                let root = try NativeProjectFolderStorage.externalRoot(selected, container: container)
                guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    selected.stopAccessingSecurityScopedResource(); refreshed.append(data); continue
                }
                guard seen.insert(root).inserted else {
                    selected.stopAccessingSecurityScopedResource(); continue
                }
                if index == 0 {
                    let directory = NativeProjectFolderStorage.projectsDirectory(in: root)
                    if (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        activeDirectory = directory
                    }
                }
                retainNativeStorageScope(selected)
                let renewed = stale ? try? selected.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
                refreshed.append(renewed ?? data)
            } catch {
                selected.stopAccessingSecurityScopedResource()
                refreshed.append(data)
            }
        }
        restoredNativeStorageBookmarks = refreshed
        if refreshed != bookmarks { defaults.set(refreshed, forKey: Self.nativeStorageBookmarksKey) }
        nativeStorageDirectory = activeDirectory
        nativeStorageNeedsAccess = activeDirectory == nil && !bookmarks.isEmpty
    }
    private func retainNativeStorageScope(_ url: URL) {
        if nativeStorageScopes.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            url.stopAccessingSecurityScopedResource()
        } else { nativeStorageScopes.append(url) }
    }
    private static func resolveNativeImportBookmark(_ data: Data) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
    private func receiveNativePackageDestination(_ root: URL) {
        guard let archive = nativePendingPackage else { return }
        defer { cancelNativePackageImport() }
        guard !busy, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        let scoped = root.startAccessingSecurityScopedResource()
        guard scoped else { error = "Could not access the selected folder."; return }
        do {
            let destination = try NativeProjectFolderStorage.externalRoot(root, container: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
            let bookmark = try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            var bookmarks = UserDefaults.standard.array(forKey: "jaras.nativeImportedProjectBookmarks") as? [Data] ?? []
            bookmarks.removeAll { (try? Self.resolveNativeImportBookmark($0).standardizedFileURL) == root.standardizedFileURL }
            bookmarks.append(bookmark)
            UserDefaults.standard.set(bookmarks, forKey: "jaras.nativeImportedProjectBookmarks")
            if nativeStorageScopes.contains(where: { $0.standardizedFileURL == root.standardizedFileURL }) {
                root.stopAccessingSecurityScopedResource()
            } else { nativeStorageScopes.append(root) }
            importPortablePackage(archive, into: destination)
        } catch {
            root.stopAccessingSecurityScopedResource()
            self.error = error.localizedDescription
        }
    }
    private func receiveNativeStorage(_ root: URL) {
        let scoped = root.startAccessingSecurityScopedResource()
        guard scoped else { error = "Could not access the selected folder."; return }
        busy = true; status = "Preparing external project folder…"; error = ""
        Task {
            var retained = false
            var resume: (() -> Void)?
            defer { if !retained { root.stopAccessingSecurityScopedResource() } }
            do {
                if ready { try await show.saveForClosing() }
                let bookmark = try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                let legacy = Self.nativeProjectsDirectory
                let container = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                let prepared = try await Task.detached(priority: .userInitiated) {
                    var coordinationError: NSError?
                    var result: Result<NativeProjectFolderStorage.Prepared, Error>?
                    NSFileCoordinator().coordinate(writingItemAt: root, options: [], error: &coordinationError) { granted in
                        result = Result { try NativeProjectFolderStorage.prepare(root: granted, legacy: legacy, container: container) }
                    }
                    if let coordinationError { throw coordinationError }
                    guard let result else { throw ProjectError.invalid("Could not access the selected folder.") }
                    return try result.get()
                }.value
                // Switch the active document only after the complete copy was verified.
                if let currentURL, let replacement = prepared.movedDocuments[currentURL.standardizedFileURL] {
                    guard let project = try await ProjectStore(url: replacement).load() else { throw ProjectError.invalid("Project not found") }
                    try await finishOpening(project, at: replacement)
                }
                let selected = root.standardizedFileURL.resolvingSymlinksInPath()
                let defaults = UserDefaults.standard
                var bookmarks = defaults.array(forKey: Self.nativeStorageBookmarksKey) as? [Data] ?? []
                bookmarks.removeAll { data in
                    data == bookmark || (try? Self.resolveNativeImportBookmark(data).standardizedFileURL.resolvingSymlinksInPath()) == selected
                }
                bookmarks.insert(bookmark, at: 0)
                defaults.set(bookmarks, forKey: Self.nativeStorageBookmarksKey)
                restoredNativeStorageBookmarks = bookmarks
                retainNativeStorageScope(root); retained = true
                nativeStorageDirectory = prepared.directory
                nativeStorageNeedsAccess = false
                recent = recent.map { prepared.movedDocuments[$0.standardizedFileURL] ?? $0 }
                for document in prepared.documents where !recent.contains(document) { recent.append(document) }
                persistRecentProjects()
                resume = afterNativeStorage; afterNativeStorage = nil
            } catch { self.error = error.localizedDescription }
            busy = false; status = ""; resume?()
        }
    }
    @Published var nativeNamePrompt = false
    @Published var nativeProjectName = ""
    private var nativePendingCreation: (scan: StemScan?, detectBPM: Bool, recordingChannels: Int?)?
    private var nativeScopedFolders: [URL] = []
    private var nativeAudioTarget: (session: UUID, song: UUID, track: UUID, position: Double)?
    func chooseNativeTrackAudio(_ track: UUID) {
        guard ready, !busy, let song = show.current, song.tracks.contains(where: { $0.id == track && $0.kind == .standard }) else { return }
        nativeAudioTarget = (show.projectSessionID, song.id, track, show.snapshot.transport.editPosition ?? show.snapshot.transport.position)
        nativePicker = .trackAudio
    }
    func chooseNativeTrackMedia(_ track: UUID) {
        guard ready, !busy, let song = show.current, song.tracks.contains(where: { $0.id == track && $0.kind.isTeleprompter }) else { return }
        nativeAudioTarget = (show.projectSessionID, song.id, track, show.snapshot.transport.editPosition ?? show.snapshot.transport.position)
        nativePicker = .trackMedia
    }
    func cancelNativePicker(kind: NativePicker? = nil) {
        if kind == .project || kind == .projectFile || kind == .projectFolder { cancelNativeProjectOpen() }
        if kind == .package || kind == .packageDestination { cancelNativePackageImport() }
        if kind == .storage || nativePicker == .storage {
            afterNativeStorage = nil
            nativePendingCreation = nil
        }
        nativePicker = nil; nativeAudioTarget = nil; cancelImport()
    }

    static var nativeProjectsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CatLive/Projects", isDirectory: true).resolvingSymlinksInPath()
    }
    func receiveNativeFiles(_ urls: [URL], kind: NativePicker) {
        nativePicker = nil
        if kind == .project || kind == .projectFile || kind == .reaper || kind == .logic { if let url = urls.first { receiveNativeProject(url) }; return }
        if kind == .projectFolder { if let url = urls.first { receiveNativeProjectFolder(url) } else { cancelNativeProjectOpen() }; return }
        if kind == .temporaryDestination { if let root = urls.first { receiveTemporaryDestination(root) }; return }
        if kind == .storage { if let root = urls.first { receiveNativeStorage(root) }; return }
        if kind == .packageDestination { if let root = urls.first { receiveNativePackageDestination(root) }; return }
        if kind == .trackAudio || kind == .trackMedia {
            guard let target = nativeAudioTarget else { return }
            nativeAudioTarget = nil
            guard target.session == show.projectSessionID, let url = urls.first else { return }
            _ = importAudio([NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)],
                            start: target.position, track: target.track, song: target.song, layout: .sameTrack)
            return
        }
        if kind == .package { if let url = urls.first { importPortablePackage(url) }; return }
        nativeScopedFolders = urls.filter { $0.startAccessingSecurityScopedResource() }
        guard !urls.isEmpty else { cancelImport(); return }
        if urls.count == 1 { folderSelectionRoot = urls[0] }
        else { folders = urls; folderReview = urls }
    }
    func confirmNativeStemFolders(_ urls: [URL]) {
        guard !busy, let root = folderSelectionRoot, !urls.isEmpty,
              urls.allSatisfy({ NativeStemFolderBrowser.contains($0, in: root) }) else { return }
        folderSelectionRoot = nil
        folders = urls; folderReview = urls
        confirmFolders(urls)
    }
    func confirmNativeStemImport(detectBPM: Bool) {
        guard let scan, !scan.folders.isEmpty else { error = "Select folders containing audio files."; return }
        guard !busy, !TrackRecording.shared.recording, !TrackRecording.shared.busy else {
            error = "Finish recording and pending operations before importing audio."; return
        }
        guard show.canControl() else { error = "Project editing is not available right now."; return }
        error = ""
        if adding { finish(scan: scan, detectBPM: detectBPM, destination: nil) }
        else {
            nativePendingCreation = (scan, detectBPM, nil)
            confirmNativeProjectName(presentPrompt: false)
        }
    }
    func confirmNativeProjectName(presentPrompt: Bool = true) {
        if isTemporary && nativePendingCreation == nil {
            do { _ = try ProjectName.validated(nativeProjectName) }
            catch { self.error = error.localizedDescription; nativeNamePrompt = true; return }
            nativePicker = .temporaryDestination; return
        }
        guard let pending = nativePendingCreation else { return }
        let name = nativeProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", name.count <= 128,
              !name.contains(where: { "/\\:".contains($0) || $0.isNewline || $0.asciiValue == 0 }) else {
            error = "Choose a project name without slashes or special path characters."; nativeNamePrompt = presentPrompt; return
        }
        guard let storage = nativeStorageDirectory else {
            afterNativeStorage = { [weak self] in self?.confirmNativeProjectName(presentPrompt: presentPrompt) }
            nativePicker = .storage; return
        }
        let directory = ProjectDirectoryPolicy.availableFolder(named: name, in: storage)
        nativePendingCreation = nil
        finish(scan: pending.scan, detectBPM: pending.detectBPM, destination: directory.appendingPathComponent(name).appendingPathExtension("jl"), recordingChannels: pending.recordingChannels)
    }
    func cancelNativeProjectName() { nativePendingCreation = nil }
    #endif
    func importPortablePackage(_ url: URL) {
        guard !busy, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        #if os(macOS)
        guard confirmPortableImportPrompt(.destination) else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.title = JarasLocalization.string("Choose a folder for the imported project")
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        importPortablePackage(url, into: selected.resolvingSymlinksInPath())
        #else
        // The selected archive owns this import until destination or cancel.
        // A late Files/Open URL callback must not restart its destination step.
        guard nativePendingPackage == nil, nativePackagePrompt == nil else { return }
        cancelNativePackageImport()
        nativePendingPackage = url
        if url.startAccessingSecurityScopedResource() { nativePackageScope = url }
        nativePackagePrompt = .destination
        #endif
    }
    #if os(macOS)
    private func confirmPortableImportPrompt(_ prompt: PortableProjectImportPrompt) -> Bool {
        let alert = NSAlert(); alert.alertStyle = .informational
        alert.messageText = JarasLocalization.string(prompt.title)
        alert.informativeText = JarasLocalization.string(prompt.message)
        alert.addButton(withTitle: JarasLocalization.string(prompt.action))
        alert.addButton(withTitle: JarasLocalization.string("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    #endif
    private func importPortablePackage(_ url: URL, into destination: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        beginOpening {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            self.status = "Importing CatLive project…"
            defer { self.audioImportProgress = nil }
            let result = try await PortableProjectPackage.importPackage(url, into: destination) { [weak self] progress in
                Task { @MainActor in self?.audioImportProgress = progress }
            }
            do {
                try Task.checkCancellation()
                try await self.finishOpening(result.project, at: result.document)
            } catch {
                // This directory was created exclusively by this import. Never
                // delete a document after it has become the active project.
                if self.currentURL != result.document { try? FileManager.default.removeItem(at: result.document.deletingLastPathComponent()) }
                throw error
            }
        }
    }
    @Published var ready = false
    @Published var opened = UUID()
    @Published var completedStemImport = UUID()
    @Published var currentURL: URL?
    @Published var recent: [URL] = []
    @Published var canCancelOpening = false
    struct OpeningProgress {
        var fraction = 0.0
        var fileName: String
        let isBackup: Bool
    }
    @Published private(set) var openingProgress: OpeningProgress?
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
    private func beginOpening(progress: OpeningProgress? = nil, _ operation: @escaping @MainActor () async throws -> Void) {
        busy = true; error = ""; status = "Opening project…"; canCancelOpening = true
        openingProgress = progress
        #if os(macOS)
        if let request = remoteOpening { Self.finishRemoteProjectOpening(request.id, state: "opening") }
        #endif
        openingCancellation = ProjectOpeningCancellation()
        openingTask = Task {
            defer {
                busy = false; canCancelOpening = false; openingTask = nil; openingCancellation = nil; status = ""
                openingProgress = nil
                #if os(macOS)
                finishRemoteOpening()
                #endif
            }
            do { try await operation() }
            catch is CancellationError { missingAudioPrompt = nil }
            catch {
                if Task.isCancelled { missingAudioPrompt = nil }
                else {
                    self.error = error.localizedDescription
                    if let progress, !progress.isBackup { show.modalNotice = self.error }
                }
            }
        }
    }
    @Published var busy = false {
        didSet { if !busy { closeNotice = "" } }
    }
    // Some operations render their own progress/cancel panel in the workspace.
    // Keep busy admission, without covering or disabling that panel at the root.
    @Published var presentsOwnProgress = false
    var showsBlockingProgress: Bool { busy && !presentsOwnProgress }
    @Published var closeNotice = ""
    @Published var status = ""
    @Published var error = ""
    @Published var folderSelectionRoot: URL?
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
        var isDAWImport = false
        var openingProgress: OpeningProgress?
    }
    @Published var missingAudioPrompt: MissingAudioPrompt?
    @Published var importingAudio = false
    @Published var audioImportProgress: Double? = nil
    @Published private(set) var temporarySaveProgress: TemporaryProjectSession.SaveProgress?
    private var temporarySaveOperation: UUID?
    @Published var audioImportError = ""
    @Published var migrationNotice = ""
    struct PendingAudioDrop: Identifiable {
        let id = UUID()
        let providers: [NSItemProvider]
        let start: Double
        let track: UUID?
        let song: UUID
        let project: UUID
        let session: UUID
    }
    @Published var pendingAudioDrop: PendingAudioDrop?
    func importAudio(_ providers: [NSItemProvider], start: Double, track: UUID?, song: UUID, layout: AudioDropLayout? = nil, gap: Double = 0) -> Bool {
        guard show.canControl(), ready, !busy, !providers.isEmpty, let destination = currentURL,
              let arrangement = show.snapshot.project.songs.first(where: { $0.id == song }) else { return false }
        let projectID = show.snapshot.project.id
        if providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.catLiveLyrics.identifier) }) {
            importLyrics(providers, at: start, song: song, project: projectID)
            return true
        }
        if let track, !arrangement.tracks.contains(where: { $0.id == track }) {
            audioImportError = "The destination track no longer exists"; return false
        }
        let destinationKind = track.flatMap { id in arrangement.tracks.first { $0.id == id }?.kind }
        if providers.count > 1, layout == nil {
            pendingAudioDrop = PendingAudioDrop(providers: providers, start: start, track: track, song: song, project: projectID, session: show.projectSessionID)
            return true
        }
        let targets = track.flatMap { id in arrangement.tracks.contains { $0.id == id } ? [id] : nil } ?? []
        let dropLayout = layout ?? .separateTracks
        let videoTrackAvailable = arrangement.tracks.contains { $0.kind == .video }
        busy = true; importingAudio = true; audioImportProgress = nil; status = "Importing audio…"; audioImportError = ""
        Task {
            defer { busy = false; importingAudio = false; audioImportProgress = nil }
            var prepared: StemProjectImporter.DroppedAudio?
            do {
                var urls: [URL] = []
                for provider in providers {
                    if provider.hasItemConformingToTypeIdentifier(LibrarySamplerTransfer.type.identifier) {
                        let sample: URL = try await withCheckedThrowingContinuation { continuation in
                            provider.loadDataRepresentation(forTypeIdentifier: LibrarySamplerTransfer.type.identifier) { data, error in
                                if let url = LibrarySamplerTransfer.url(data) { continuation.resume(returning: url) }
                                else { continuation.resume(throwing: error ?? ProjectError.invalid("Could not read the dropped file.")) }
                            }
                        }
                        urls.append(sample)
                        continue
                    }
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
                let lyrics = sources.filter { $0.pathExtension.lowercased() == "jllyrics" }
                if !lyrics.isEmpty {
                    guard lyrics.count == sources.count else { throw ProjectError.invalid("Drop lyrics separately from audio and video.") }
                    let documents = try await Task.detached(priority: .utility) {
                        try lyrics.map { source in
                            let grant = source.startAccessingSecurityScopedResource()
                            defer { if grant { source.stopAccessingSecurityScopedResource() } }
                            return try JSONDecoder().decode(JLLyricsDocument.self, from: Data(contentsOf: source))
                        }
                    }.value
                    try show.insertLyrics(documents, at: start, song: song, project: projectID)
                    return
                }
                let scoped = sources.filter { $0.startAccessingSecurityScopedResource() }
                defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
                prepared = try await Task.detached(priority: .userInitiated) {
                    try StemProjectImporter.prepareDroppedAudio(sources, start: start, destinationTracks: targets, destination: destination, layout: dropLayout, gap: gap, destinationKind: destinationKind, videoTrackAvailable: videoTrackAvailable, deferWaveform: true) { [weak self] current, total, name in
                        Task { @MainActor [weak self] in
                            self?.status = "Importing \(current)/\(total): \(name)"
                            self?.audioImportProgress = total > 0 ? min(1, Double(current) / Double(total)) : nil
                        }
                    }
                }.value
                if let prepared {
                    for imported in prepared.tracks where imported.kind == .video || imported.kind.isTeleprompter {
                        guard show.snapshot.project.songs.first(where: { $0.id == song })?.tracks.contains(where: { $0.id == imported.id && $0.kind == imported.kind }) == true else {
                            throw ProjectError.invalid("The destination Video track no longer exists")
                        }
                    }
                    // Visible items request their waveform cache asynchronously.
                    // Insert first: analysis must never gate the drop or mutate
                    // the project later (which could resurrect an undone item).
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
    func pasteGridItems(selectedTracks: Set<UUID>, completion: @escaping (Set<UUID>) -> Void) {
        let board = GridMediaClipboard.shared
        guard board.source() == .items, let payload = board.items else { return }
        if board.session == show.projectSessionID {
            completion(show.pasteItems(selectedTracks: selectedTracks)); return
        }
        guard !payload.moving, ready, !busy, show.canControl(), let song = show.current else { return }
        let session = show.projectSessionID
        let position = show.snapshot.transport.editPosition ?? show.snapshot.transport.position
        do {
            let plan = try payload.copyPlan(in: song, at: position, selectedTracks: selectedTracks)
            let entries = plan.entries
            var validation = show.snapshot.project
            try validation.pasteItems(entries, song: song.id, moving: false, addingTracks: plan.newTracks)
            let source = board.directory, destination = currentURL?.deletingLastPathComponent() ?? projectAudio.mediaDirectory
            busy = true; status = "Copying media…"
            Task {
                defer { busy = false; status = "" }
                do {
                    let transfer = try await Task.detached(priority: .userInitiated) {
                        try GridItemMediaTransfer.stage(entries, from: source, to: destination)
                    }.value
                    do {
                        guard show.projectSessionID == session else { throw CancellationError() }
                        completion(try show.pasteTransferredItems(transfer.entries, song: song.id, addingTracks: plan.newTracks))
                    } catch { transfer.discard(); throw error }
                } catch { show.modalNotice = error.localizedDescription }
            }
        } catch { show.modalNotice = error.localizedDescription }
    }
    func pasteMedia(_ urls: [URL], track: UUID?) {
        guard show.canControl(), ready, !busy, !urls.isEmpty,
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
    // The Remote connection survives tab changes. Keep the last acknowledged
    // operation outside an individual document, including a failed new tab.
    private static var remoteOpeningID: UUID?
    private static var remoteOpeningState: String?
    private static var remoteOpeningError = ""
    private var remoteOpening: (id: UUID, destination: URL)?
    private func updateRemoteOpeningDestination(_ id: UUID?, to destination: URL) {
        guard let id, remoteOpening?.id == id else { return }
        remoteOpening?.destination = destination.standardizedFileURL.resolvingSymlinksInPath()
    }
    static func finishRemoteProjectOpening(_ id: UUID, state: String, error: String = "") {
        guard remoteOpeningID == id else { return }
        remoteOpeningState = state; remoteOpeningError = error
    }
    private func finishRemoteOpening() {
        guard let request = remoteOpening else { return }
        if missingAudioPrompt != nil {
            Self.finishRemoteProjectOpening(request.id, state: "waiting")
            return
        }
        let opened = ready && currentURL?.standardizedFileURL.resolvingSymlinksInPath() == request.destination
        Self.finishRemoteProjectOpening(request.id, state: error.isEmpty ? (opened ? "completed" : "cancelled") : "failed",
            error: error.isEmpty ? "" : "Could not open the project. Check the Mac for details.")
        remoteOpening = nil
    }
    var remoteProjectBrowser: DAWRemoteState.ProjectBrowser {
        let recent = remoteProjectCatalog.update(self.recent, current: currentURL)
        let recording = TrackRecording.shared.recording || TrackRecording.shared.busy
        let busy = self.busy || show.saving
        let status = busy ? (self.status.isEmpty ? "Opening project…" : self.status) : missingAudioPrompt != nil ?
            "Resolve missing audio on the Mac to continue." : recording ? "Stop recording on the Mac to open a project." : ""
        let error = !Self.remoteOpeningError.isEmpty ? Self.remoteOpeningError : !remoteProjectError.isEmpty ? remoteProjectError : missingAudioPrompt != nil ?
            "Resolve missing audio on the Mac to continue." : self.error.isEmpty ? "" :
            "Could not open the project. Check the Mac for details."
        return .init(recent: recent, busy: busy,
                     canOpen: !busy && !importingAudio && !recording && missingAudioPrompt == nil && canChangeProject(),
                     canOpenInNewTab: openInNewProjectTab != nil, status: status, error: error,
                     commandID: Self.remoteOpeningID, commandState: Self.remoteOpeningState)
    }
    func openRemoteProject(_ id: UUID, inNewTab: Bool = false, commandID: UUID = UUID()) {
        remoteProjectError = ""
        Self.remoteOpeningID = commandID; Self.remoteOpeningState = "opening"; Self.remoteOpeningError = ""
        guard remoteProjectBrowser.canOpen else {
            Self.finishRemoteProjectOpening(commandID, state: "failed", error: "Finish the current operation before opening another project.")
            return
        }
        guard let url = remoteProjectCatalog.url(for: id) else {
            remoteProjectError = "This project is no longer in the Mac’s recent projects."
            Self.finishRemoteProjectOpening(commandID, state: "failed", error: remoteProjectError)
            return
        }
        guard url.standardizedFileURL.resolvingSymlinksInPath() != currentURL?.standardizedFileURL.resolvingSymlinksInPath() else {
            Self.finishRemoteProjectOpening(commandID, state: "completed"); return
        }
        if inNewTab {
            if let openRemoteInNewProjectTab { openRemoteInNewProjectTab(url, commandID) }
            else { Self.finishRemoteProjectOpening(commandID, state: "failed", error: "Opening a new project tab is unavailable.") }
            return
        }
        // The normal document transition flushes unsaved changes before replacing
        // the project, and keeps the current project if saving or loading fails.
        open(url, remoteCommandID: commandID)
    }
    #endif
    init(store: DocumentProjectStore, show: ShowController, preview: Bool) {
        self.store = store; self.show = show; ready = preview
        show.explicitSaveHandler = { [weak self] in
            guard let self, self.isTemporary else { return false }
            await self.saveTemporary(); return true
        }
        let stored = UserDefaults.standard.stringArray(forKey: "jaras.recentProjects") ?? []
        #if os(iOS)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        recent = stored.map { NativeRecentProjectPath.resolve($0, documents: documents) }
        restoreNativeImportedFolders()
        refreshNativeStorage()
        persistRecentProjects()
        #else
        recent = stored.map { URL(fileURLWithPath: $0) }
        #endif
        #if os(macOS)
        DAWRemoteHostBridge.documents = self
        #endif
    }
    #if os(iOS)
    deinit {
        nativeStorageScopes.forEach { $0.stopAccessingSecurityScopedResource() }
        nativeProjectScope?.stopAccessingSecurityScopedResource()
        nativePackageScope?.stopAccessingSecurityScopedResource()
        nativeScopedFolders.forEach { $0.stopAccessingSecurityScopedResource() }
    }
    #endif
    private func persistRecentProjects() {
        #if os(iOS)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let paths = recent.map { NativeRecentProjectPath.store($0, documents: documents) }
        #else
        let paths = recent.map(\.path)
        #endif
        UserDefaults.standard.set(paths, forKey: "jaras.recentProjects")
    }
    private func remember(_ url: URL) {
        guard temporarySession?.contains(url) != true else { return }
        ProjectDocumentAppearance.apply(to: url)
        recent.removeAll { $0 == url }; recent.insert(url, at: 0); recent = Array(recent.prefix(20))
        persistRecentProjects()
    }
    func renameProject(_ value: String) async throws {
        guard ready, !busy, !show.saving, let currentURL else { throw ProjectError.invalid("No project is open for saving.") }
        let name = try ProjectName.validated(value)
        let destination = currentURL.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension("jl")
        guard destination == currentURL || !FileManager.default.fileExists(atPath: destination.path) else {
            throw ProjectError.invalid("A project with this name already exists.")
        }
        busy = true
        defer { busy = false }
        try show.renameProject(name)
        try await show.flushProject()
        try await store.rename(to: destination, id: show.snapshot.project.id)
        self.currentURL = destination
        recent.removeAll { $0.standardizedFileURL == currentURL.standardizedFileURL }
        remember(destination)
    }
    @Published var pendingDeletion: ProjectDeletionPrompt?
    func requestDeletion(_ url: URL) {
        guard !busy, !show.saving, !TrackRecording.shared.recording,
              !TrackRecording.shared.busy, !importingAudio else { return }
        error = ""
        let prompt = ProjectDeletionPrompt(document: url)
        pendingDeletion = prompt
        Task {
            do {
                let plan = try await Task.detached(priority: .userInitiated) { () -> ProjectFolderDeletion? in
                    guard !RecentProjectEntry.isMissing(url) else { return nil }
                    return try ProjectFolderDeletion(document: url, availableAt: prompt.availableAt)
                }.value
                guard pendingDeletion?.id == prompt.id else { return }
                guard let plan else {
                    recent.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
                    persistRecentProjects(); pendingDeletion = nil
                    return
                }
                pendingDeletion?.plan = plan
            } catch {
                guard pendingDeletion?.id == prompt.id else { return }
                self.error = error.localizedDescription
            }
        }
    }
    func deleteProject(_ deletion: ProjectFolderDeletion) {
        guard pendingDeletion?.plan?.id == deletion.id, deletion.remainingSeconds == 0,
              !busy, !show.saving, !TrackRecording.shared.recording,
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
                closeProjectEditors()
                if TeleprompterWindow.shared.visible { TeleprompterWindow.shared.toggle(show: show) }
                if TeleprompterWindow.second.visible { TeleprompterWindow.second.toggle(show: show) }
                TeleprompterRemote.setProjectDirectory(nil)
                #endif
                VideoPlayback.shared.closeProject()
                VideoPlayback.teleprompter.closeProject()
                VideoPlayback.teleprompter2.closeProject()
                TrackRecording.shared.closeProject()
                projectAudio.prepareForClosing()
                await store.deselect()
                try await Task.detached(priority: .userInitiated) { try deletion.remove() }.value
                recent.removeAll { deletion.contains($0) }
                persistRecentProjects()
                try show.replaceProject(.empty(name: "Untitled"))
                resetProjectSelections()
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
                    try await projectAudio.openPreparedProject(directory: directory, project: show.snapshot.project)
                    VideoPlayback.shared.open(directory: directory)
                    VideoPlayback.teleprompter.open(directory: directory)
                    VideoPlayback.teleprompter2.open(directory: directory)
                    TrackRecording.shared.open(directory: directory, project: show.snapshot.project.id)
                    #if os(macOS)
                    TeleprompterRemote.setProjectDirectory(directory)
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
        ready && currentURL != nil && !busy && !show.saving &&
        !TrackRecording.shared.recording && !TrackRecording.shared.busy && !importingAudio
    }
    func cleanTimelineMedia() async throws {
        guard canCleanTimelineMedia, let currentURL else {
            throw ProjectError.invalid("Finish recording and imports before cleaning timeline files.")
        }
        busy = true
        let canExecute = show.canExecute
        show.canExecute = { false }
        defer { busy = false; show.canExecute = canExecute }
        try await show.saveForClosing()
        let project = show.snapshot.project, known = show.knownMediaPaths
        let protectedURLs = additionalProtectedMediaURLs().union(projectAudio.activeMediaURLs)
        // Once deletion starts, undo cannot restore references to removed sources,
        // including if a later filesystem operation fails halfway through.
        show.discardClosedHistory()
        try await Task.detached(priority: .userInitiated) {
            try ProjectMediaCleanup.remember(project: project, document: currentURL, knownPaths: known)
            try ProjectMediaCleanup.removeDeletedFiles(project: project, document: currentURL, knownPaths: known, protectedURLs: protectedURLs)
        }.value
    }
    var canConvertTimelineAudio: Bool {
        canCleanTimelineMedia && show.canControl() && !show.snapshot.transport.playing && !show.snapshot.transport.subPlay.playing
    }
    func convertTimelineAudioToMP3(progress: @escaping @MainActor @Sendable (Int, Int) -> Void) async throws -> Int {
        guard canConvertTimelineAudio, let document = currentURL else {
            throw ProjectError.invalid("Stop playback and finish recording or importing before converting timeline audio.")
        }
        let project = show.snapshot.project
        let paths = Set(project.songs.flatMap(\.tracks).flatMap { track in
            [track.audioFile?.path].compactMap { $0 } + track.clips.compactMap { $0.audioFile?.path }
        }).filter { path in
            let ext = (path as NSString).pathExtension.lowercased()
            return !path.hasPrefix("Videos/") && ext != "mp3" && AudioSeparation.audioExtensions.contains(ext)
        }.sorted()
        guard !paths.isEmpty else { return 0 }
        let session = show.projectSessionID, revision = show.projectRevision
        let directory = document.deletingLastPathComponent()
        busy = true
        defer { busy = false }
        progress(0, paths.count)
        let converted = try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let stems = directory.appendingPathComponent("Stems", isDirectory: true)
            try fm.createDirectory(at: stems, withIntermediateDirectories: true)
            let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
            guard stems.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/") else {
                throw ProjectError.invalid("Invalid project media path.")
            }
            var folder = stems.appendingPathComponent("MP3 Max", isDirectory: true)
            var suffix = 1
            while fm.fileExists(atPath: folder.path) {
                suffix += 1
                folder = stems.appendingPathComponent("MP3 Max \(suffix)", isDirectory: true)
            }
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            var complete = false
            defer { if !complete { try? fm.removeItem(at: folder) } }
            var names = Set<String>(), replacements: [String: AudioFile] = [:]
            for (index, path) in paths.enumerated() {
                let source = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
                let base = source.deletingPathExtension().lastPathComponent
                var name = base + ".mp3", duplicate = 1
                while !names.insert(name.lowercased()).inserted {
                    duplicate += 1
                    name = "\(base) - \(duplicate).mp3"
                }
                let target = folder.appendingPathComponent(name)
                do {
                    try JarasMP3Encoder.encodeWav(source, to: target)
                    let output = try AVAudioFile(forReading: target)
                    guard output.length > 0 else { throw ProjectError.invalid("The converted audio is empty.") }
                } catch {
                    throw ProjectError.invalid(source.lastPathComponent + " — " + error.localizedDescription)
                }
                replacements[path] = AudioFile(path: "Stems/" + folder.lastPathComponent + "/" + name)
                await progress(index + 1, paths.count)
            }
            complete = true
            return (folder, replacements)
        }.value
        guard show.projectSessionID == session, show.projectRevision == revision, currentURL == document,
              !show.snapshot.transport.playing, !show.snapshot.transport.subPlay.playing else {
            try? FileManager.default.removeItem(at: converted.0)
            throw ProjectError.invalid("The project changed during conversion. Please try again.")
        }
        guard show.replaceTimelineAudio(converted.1) else {
            throw ProjectError.invalid(show.message)
        }
        try await show.flushProject()
        return converted.1.count
    }
    private func preloadTimelineWaveforms(_ project: Project, at url: URL, unreadableAudioPaths: Set<String> = []) async {
        let directory = url.deletingLastPathComponent()
        let missing = await Task.detached(priority: .userInitiated) {
            Set(ProjectAudioRecovery.missingPaths(in: project, directory: directory)).union(unreadableAudioPaths)
        }.value
        let files = project.songs.flatMap(\.tracks).filter { $0.kind == .standard }.flatMap { track in
            track.clips.compactMap { clip -> URL? in
                guard !clip.isImage, let file = clip.audioFile ?? track.audioFile, !missing.contains(file.path) else { return nil }
                return directory.appendingPathComponent(file.path)
            }
        }
        #if os(macOS)
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
        #endif
        // Prepare missing/outdated peaks before exposing the workspace on every
        // platform. Panning or zooming must not start whole-file decoding.
        status = "Preparing waveforms…"
        let cancellation = openingCancellation
        #if os(iOS)
        let cachedOnly = true // Reuse portable WF; missing peaks are built by the visible-source worker.
        #else
        let cachedOnly = false
        #endif
        await TimelineAudioWaveform.shared.preload(files, cachedOnly: cachedOnly, cancelled: { cancellation?.cancelled == true }) { done, total in
            guard cancellation?.cancelled != true else { return }
            self.status = "Preparing waveforms… \(done)/\(total)"
            if let progress = self.openingProgress {
                let start = progress.isBackup ? 0.8 : 0.25
                self.openingProgress?.fraction = max(progress.fraction, start + (0.9 - start) * Double(done) / Double(max(1, total)))
            }
        }
    }
    private func closeProjectEditors() {
        #if os(macOS)
        // Closing FX captures their last preset, so it must happen while the
        // controller and audio engine still refer to the outgoing document.
        FXWindows.shared.closeAll()
        AutomationWindows.closeAll()
        MIDIEditorWindows.shared.closeAll()
        #endif
    }
    private func confirmOutgoingProject() async throws {
        guard ready, show.hasUnsavedChanges else { return }
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = String(format: JarasLocalization.string("Do you want to save the project %@?"), show.snapshot.project.name)
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: JarasLocalization.string("Don't Save"))
        alert.addButton(withTitle: JarasLocalization.string("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if isTemporary, let lease = temporarySession {
                let panel = NSSavePanel()
                panel.title = JarasLocalization.string("Save Project")
                panel.allowedContentTypes = [UTType(filenameExtension: "jl") ?? .data]
                panel.nameFieldStringValue = "Untitled.jl"
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let selected = panel.url else { throw CancellationError() }
                let name = selected.deletingPathExtension().lastPathComponent
                let destination = ProjectDirectoryPolicy.availableFolder(named: name, in: selected.deletingLastPathComponent())
                    .appendingPathComponent(name).appendingPathExtension("jl")
                try await show.saveForClosing()
                guard let saved = try await store.load() else { throw ProjectError.invalid("Project not found") }
                _ = try await Task.detached(priority: .userInitiated) { try lease.export(saved, to: destination) }.value
                remember(destination)
            } else {
                try await show.saveForClosing()
            }
        case .alertSecondButtonReturn:
            break
        default:
            throw CancellationError()
        }
        #else
        try await show.saveForClosing()
        #endif
    }
    private func resetProjectSelections() {
        pendingAudioDrop = nil; audioImportError = ""
        TeleprompterTimerController.shared.stopAndReset()
        AudioExportSelection.shared.clear()
        TimelineAreaSelection.shared.clear()
        SetlistSessionState.reset()
        TrackMixerRow.resetProjectSession()
        #if os(macOS)
        TPNoticeController.shared.clear()
        #endif
    }
    #if os(iOS)
    /// Leaving the workspace closes the document, rather than retaining a
    /// hidden project behind the browser. Failed saves keep it open.
    func closeNativeProject(suspendAudio: () async throws -> Void) async throws {
        guard !busy, !importingAudio else { throw ProjectError.invalid("Finish the current operation before closing.") }
        busy = true; error = ""; status = "Closing…"
        show.send(.stopAll)
        let canExecute = show.canExecute
        show.canExecute = { false }
        defer { show.canExecute = canExecute; busy = false; status = "" }
        await TrackRecording.shared.finishAndWait()
        if ready && !isTemporary {
            try await show.saveForClosing()
            try await rememberProjectMedia()
        }
        // Do not detach nodes while a hardware stop still owns the engine.
        try await suspendAudio()
        try show.replaceProject(.empty(name: "Untitled"))
        await store.deselect()
        ready = false; currentURL = nil; opened = UUID()
        VideoPlayback.shared.closeProject()
        VideoPlayback.teleprompter.closeProject()
        VideoPlayback.teleprompter2.closeProject()
        TrackRecording.shared.closeProject()
        projectAudio.prepareForClosing()
        resetProjectSelections()
        clearImportSelection()
        cancelNativePackageImport(); nativePicker = nil; nativeAudioTarget = nil
        nativePendingCreation = nil; afterNativeStorage = nil
        warnings = []; missingAudioPaths = []; missingAudioPrompt = nil
        migrationNotice = ""; pendingDeletion = nil
        await TimelineAudioWaveform.shared.closeProject()
        try discardTemporarySession()
    }
    #endif
    private func activate(_ project: Project, at url: URL, unreadableAudioPaths: Set<String> = [],
                          confirmReplacement: Bool = true) async throws {
        var project = project
        for song in project.songs.indices {
            for track in project.songs[song].tracks.indices where project.songs[song].tracks[track].role.rawValue == "video" {
                project.songs[song].tracks[track].role = .other
            }
        }
        if GlobalProjectTiming.load() == nil, let song = project.songs.first { GlobalProjectTiming(song: song).save() }
        try project.validate()
        await preloadTimelineWaveforms(project, at: url, unreadableAudioPaths: unreadableAudioPaths)
        status = "Preparing audio…"
        await Task.yield()
        #if os(macOS)
        // File reading and waveform preparation can overlap the startup sound;
        // resetting the hardware graph must wait until that sound has finished.
        try await AppStartupPresentation.waitForSound()
        #endif
        try Task.checkCancellation()
        canCancelOpening = false
        openingProgress?.fraction = 0.95
        let canExecute = show.canExecute
        show.canExecute = { false }
        defer { show.canExecute = canExecute }
        closeProjectEditors()
        if confirmReplacement { try await confirmOutgoingProject() }
        if currentURL != url { try await rememberProjectMedia() }
        // Keep the current project playing through preparation and saving.
        // Only its actual replacement stops this session; other tabs keep playing.
        show.send(.stopAll)
        // Loading can still fail in the backend after model validation. Keep
        // saves attached to the previous document until replacement succeeds.
        try show.replaceProject(project)
        resetProjectSelections()
        await store.select(url: url, savedProject: project)
        let missing = Set(ProjectAudioRecovery.missingPaths(in: project, directory: url.deletingLastPathComponent())).union(unreadableAudioPaths)
        try await projectAudio.openPreparedProject(directory: url.deletingLastPathComponent(), project: show.snapshot.project)
        projectAudio.setMissingAudioPaths(missing)
        VideoPlayback.shared.open(directory: url.deletingLastPathComponent())
        VideoPlayback.teleprompter.open(directory: url.deletingLastPathComponent())
        VideoPlayback.teleprompter2.open(directory: url.deletingLastPathComponent())
        #if os(macOS)
        TeleprompterRemote.setProjectDirectory(url.deletingLastPathComponent())
        #endif
        VideoPlayback.shared.update(show.snapshot, revision: show.projectRevision)
        TrackRecording.shared.open(directory: url.deletingLastPathComponent(), project: show.snapshot.project.id)
        show.preparePlayback()
        missingAudioPaths = missing
        currentURL = url; remember(url); ready = true; opened = UUID()
        if PlaybackCapacity.peak(project) > PlaybackCapacity.limit {
            show.modalNotice = JarasLocalization.string(PlaybackCapacity.openingNotice)
        }
        openingProgress?.fraction = 1
        if let temporarySession, !temporarySession.contains(url) {
            // Playback/readers now point at the new directory. Cleanup failure
            // must not invalidate an already committed/opened normal project.
            do { try temporarySession.discard(); self.temporarySession = nil }
            catch { self.error = error.localizedDescription }
        }
    }
    private func finishOpening(_ project: Project, at url: URL) async throws {
        status = "Preparing waveforms…"
        let prepared = try await ProjectOpeningWork.run {
            var ignored = Set<String>(), notices: [String] = []
            let enriched = try StemProjectImporter.populateChannelOverviews(project, directory: url.deletingLastPathComponent(), onUnreadable: { path, error in
                ignored.insert(path); notices.append(path + "\n" + error.localizedDescription)
            })
            return (enriched, ignored, notices)
        }
        let enriched = prepared.0
        try Task.checkCancellation()
        try await activate(enriched, at: url, unreadableAudioPaths: prepared.1)
        warnings += prepared.2
        if enriched != project { try await ProjectStore(url: url).save(enriched) }
    }
    func open(_ url: URL) { open(url, remoteCommandID: nil) }
    func open(_ url: URL, remoteCommandID: UUID? = nil, fromFileRecents: Bool = false) {
        #if os(macOS)
        if let remoteCommandID { remoteOpening = (remoteCommandID, url.standardizedFileURL.resolvingSymlinksInPath()) }
        guard canChangeProject(), !importingAudio else {
            if let remoteCommandID {
                Self.finishRemoteProjectOpening(remoteCommandID, state: "failed", error: "Finish the current operation before opening another project.")
                remoteOpening = nil
            }
            return
        }
        #endif
        if activateExistingProjectTab?(url) == true {
            #if os(macOS)
            if let remoteCommandID { Self.finishRemoteProjectOpening(remoteCommandID, state: "completed"); remoteOpening = nil }
            #endif
            return
        }
        guard !busy, !TrackRecording.shared.recording, !TrackRecording.shared.busy else {
            #if os(macOS)
            if let remoteCommandID {
                Self.finishRemoteProjectOpening(remoteCommandID, state: "failed", error: "Finish the current operation before opening another project.")
                remoteOpening = nil
            }
            #endif
            return
        }
        // Recent Projects and Finder can both request the document already in
        // memory. Reloading its older disk snapshot would discard current edits
        // after activate() saves them, including when the path is an alias.
        if ready, let currentURL,
           currentURL.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() {
            #if os(macOS)
            finishRemoteOpening()
            #endif
            return
        }
        if ["ziplive", "zip"].contains(url.pathExtension.lowercased()) { importPortablePackage(url); return }
        #if os(macOS)
        if ["logicx", "rpp"].contains(url.pathExtension.lowercased()) { importDAW(url); return }
        #endif
        let isBackup = url.pathExtension.lowercased() == "bkjl"
        let progress = isBackup || (ready && fromFileRecents) ? OpeningProgress(fileName: url.lastPathComponent, isBackup: isBackup) : nil
        beginOpening(progress: progress) {
            guard ["jl", "bkjl"].contains(url.pathExtension.lowercased()) else { throw ProjectError.invalid("Select a .jl or .bkjl project") }
            let opening = self.openingCancellation
            if isBackup { self.status = "Restoring backup…" }
            let url = try await ProjectOpeningWork.run {
                guard isBackup else { return url }
                return try ProjectBackups.restore(url) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.openingCancellation === opening, opening?.cancelled != true,
                              let current = self.openingProgress, current.fraction <= progress.fraction * 0.7 else { return }
                        self.openingProgress?.fraction = progress.fraction * 0.7
                        self.openingProgress?.fileName = progress.fileName
                    }
                }
            }
            if isBackup {
                self.openingProgress?.fraction = 0.75
                self.openingProgress?.fileName = ""
                self.status = "Opening project…"
            }
            #if os(macOS)
            self.updateRemoteOpeningDestination(remoteCommandID, to: url)
            #endif
            guard let project = try await ProjectStore(url: url).load() else { throw ProjectError.invalid("Project not found") }
            try Task.checkCancellation()
            try project.validate()
            if !isBackup { self.openingProgress?.fraction = 0.15 }
            let missing = try await ProjectOpeningWork.run {
                ProjectAudioRecovery.missingPaths(in: project, directory: url.deletingLastPathComponent())
            }
            try Task.checkCancellation()
            if !isBackup { self.openingProgress?.fraction = 0.25 }
            if !missing.isEmpty {
                self.missingAudioPrompt = MissingAudioPrompt(project: project, url: url, paths: missing, openingProgress: self.openingProgress)
                return
            }
            try await self.finishOpening(project, at: url)
        }
    }
    func searchMissingAudio(in folder: URL) {
        guard !busy, let prompt = missingAudioPrompt else { return }
        busy = true; status = "Searching for missing audio…"
        Task {
            defer {
                busy = false
                #if os(macOS)
                finishRemoteOpening()
                #endif
            }
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ProjectAudioRecovery.restore(prompt.project, directory: prompt.url.deletingLastPathComponent(), searching: folder)
                }.value
                if result.remaining.isEmpty {
                    try await finishOpening(prompt.project, at: prompt.url)
                    missingAudioPrompt = nil
                    if prompt.isDAWImport { migrationNotice = warnings.joined(separator: "\n\n") }
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
        beginOpening(progress: prompt.openingProgress) {
            try await self.finishOpening(prompt.project, at: prompt.url)
            self.missingAudioPrompt = nil
            if prompt.isDAWImport {
                self.warnings += prompt.paths.map { $0 + "\n" + JarasLocalization.string("Media file was not found.") }
                self.migrationNotice = self.warnings.joined(separator: "\n\n")
            }
        }
    }
    func cancelMissingAudioOpen() {
        if canCancelOpening { cancelOpening() }
        else if !busy {
            missingAudioPrompt = nil
            #if os(macOS)
            finishRemoteOpening()
            #endif
        }
    }
    #if os(macOS)
    func chooseMigration(_ fileExtension: String) {
        guard !busy, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
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
        guard show.canControl() else { return }
        let isReaper = source.pathExtension.lowercased() == "rpp"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "jl") ?? .data]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".jl"
        panel.title = JarasLocalization.string(isReaper ? "Import REAPER project" : "Import Logic project")
        panel.message = JarasLocalization.string("A separate folder with this project name will be created in the chosen location for the CatLive project, media and backups.")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        let destination = ProjectMigration.isolatedDestination(for: selected)
        guard !destination.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/") else {
            error = "Save the CatLive project outside the Logic package."; return
        }
        do { try ProjectDirectoryPolicy.validate(destination) }
        catch { self.error = ProjectMigration.errorDescription(error, localize: { JarasLocalization.string($0) }); return }
        busy = true; error = ""; warnings = []; migrationNotice = ""
        status = isReaper ? "Importing REAPER project…" : "Importing Logic project…"
        let pluginImport = isReaper ? Bundle.main.executableURL.map {
            ReaperVST3ImportSession(executable: $0, catalog: PluginCatalog.shared.plugins, paths: PluginCatalog.shared.paths)
        } : nil
        let warningBundle = JarasLocalization.bundle()
        Task {
            defer { busy = false }
            do {
                let (result, teleprompter) = try await Task.detached(priority: .userInitiated) {
                    let result = try isReaper ? ReaperProjectImporter.read(source, resolveVST3: pluginImport.map { session in { try session.resolve($0) } }, localizeWarning: { warningBundle.localizedString(forKey: $0, value: $0, table: nil) }) : LogicProjectImporter.read(source, localizeWarning: { warningBundle.localizedString(forKey: $0, value: $0, table: nil) })
                    try ProjectMigration.save(result, to: destination)
                    return (result, isReaper ? VSHookTeleprompterMigration.read(for: source) : nil)
                }.value
                if let pluginImport { PluginCatalog.shared.acceptImportedPlugins(pluginImport.discovered) }
                if VSHookTeleprompterMigration.applyOnce(teleprompter) {
                    TeleprompterPreferences.shared.reload(); TeleprompterPreferences.second.reload()
                    TPNoticeController.shared.reload()
                }
                warnings = result.warnings.map { JarasLocalization.string($0) }
                let missing = ProjectAudioRecovery.missingPaths(in: result.project, directory: destination.deletingLastPathComponent())
                if !missing.isEmpty {
                    missingAudioPrompt = MissingAudioPrompt(project: result.project, url: destination, paths: missing, isDAWImport: true)
                } else {
                    try await finishOpening(result.project, at: destination)
                    migrationNotice = warnings.joined(separator: "\n\n")
                }
            } catch { self.error = ProjectMigration.errorDescription(error, localize: { JarasLocalization.string($0) }) }
        }
    }
    #endif
    func browse(onlyCatLiveProject: Bool = false) {
        #if os(macOS)
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "ziplive") ?? .zip, .zip, UTType(filenameExtension: "jl") ?? .data, UTType(filenameExtension: "bkjl") ?? .data, UTType(filenameExtension: "logicx") ?? .package, UTType(filenameExtension: "rpp") ?? .data, .package, .folder]
        if onlyCatLiveProject { panel.allowedContentTypes = [UTType(filenameExtension: "jl") ?? .data] }
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = !onlyCatLiveProject
        panel.treatsFilePackagesAsDirectories = false
        let validator = ProjectSourcePanelValidator(extensions: onlyCatLiveProject ? ["jl"] : ["jl", "bkjl", "logicx", "rpp", "ziplive", "zip"])
        panel.delegate = validator
        let response = withExtendedLifetime(validator) { panel.runModal() }
        if response == .OK, let url = panel.url { open(url) }
        #else
        guard !busy, !TrackRecording.shared.recording, !TrackRecording.shared.busy,
              nativePicker == nil, nativePackagePrompt == nil else { return }
        cancelNativeProjectOpen(); cancelNativePackageImport()
        nativePicker = onlyCatLiveProject ? .projectFile : .project
        #endif
    }
    #if os(macOS)
    func saveAs() async {
        guard ready, !busy, !show.saving, !TrackRecording.shared.recording,
              !TrackRecording.shared.busy, let source = currentURL else { return }
        if isTemporary { await saveTemporary(); return }
        let panel = NSSavePanel()
        panel.title = "Save As"
        panel.allowedContentTypes = [UTType(filenameExtension: "jl") ?? .data]
        panel.nameFieldStringValue = source.lastPathComponent
        panel.directoryURL = source.deletingLastPathComponent().deletingLastPathComponent()
        panel.canCreateDirectories = true
        let validator = ProjectCopyPanelValidator(source: source)
        panel.delegate = validator
        let session = show.projectSessionID
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let window = NSApp.keyWindow { panel.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
            else { panel.begin { continuation.resume(returning: $0) } }
        }
        guard response == .OK, let target = panel.url, show.projectSessionID == session, !busy else { return }
        _ = validator
        busy = true; status = "Copying audio and saving project…"
        temporarySaveProgress = .preparing
        let canExecute = show.canExecute
        defer { busy = false; status = ""; temporarySaveProgress = nil; show.canExecute = canExecute }
        do {
            closeProjectEditors()
            let project = try show.projectForSaving()
            show.canExecute = { false }
            let result = try await Task.detached(priority: .userInitiated) {
                try TemporaryProjectSession.copyProject(project, from: source.deletingLastPathComponent(), to: target) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.busy, progress.sequence >= (self.temporarySaveProgress?.sequence ?? 0) else { return }
                        self.temporarySaveProgress = progress
                    }
                }
            }.value
            try await activate(result, at: target, confirmReplacement: false)
        } catch { show.modalNotice = error.localizedDescription }
    }

    enum TimelineFileKind { case audio, movie, midi }
    func importTimelineFile(_ kind: TimelineFileKind) {
        guard ready, !busy, let song = show.current else { return }
        guard let id = show.selectedTrackForActions, let track = song.tracks.first(where: { $0.id == id }),
              kind == .movie ? track.kind == .video || track.kind.isTeleprompter : track.kind == .standard && track.role.rawValue != "vinhetas" else {
            audioImportError = JarasLocalization.string("Select another track.")
            return
        }
        let panel = NSOpenPanel()
        switch kind {
        case .audio: panel.allowedContentTypes = [.audio]
        case .movie: panel.allowedContentTypes = [.movie]
        case .midi: panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .midi, .midi]
        }
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        let cursor = show.snapshot.transport.editPosition ?? show.snapshot.transport.position
        let project = show.snapshot.project.id, session = show.projectSessionID
        guard panel.runModal() == .OK, let url = panel.url, show.projectSessionID == session,
              show.current?.id == song.id, show.current?.tracks.contains(where: { $0.id == id && $0.kind == track.kind }) == true else { return }
        if kind != .midi {
            _ = importAudio([NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)],
                            start: cursor, track: id, song: song.id, layout: .sameTrack)
            return
        }
        do {
            var imported = track
            imported.clips = [try Self.readMIDIItem(url, start: cursor)]
            try show.insertAudioTracks([imported], song: song.id, project: project)
        } catch { audioImportError = error.localizedDescription }
    }

    nonisolated private static func readMIDIItem(_ url: URL, start: Double) throws -> AudioClip {
        let unreadable = ProjectError.invalid("Could not read the MIDI file.")
        var source: MusicSequence?
        guard NewMusicSequence(&source) == noErr, let source else { throw unreadable }
        defer { DisposeMusicSequence(source) }
        guard MusicSequenceFileLoad(source, url as CFURL, .midiType, []) == noErr else { throw unreadable }
        var count: UInt32 = 0
        MusicSequenceGetTrackCount(source, &count)
        var notes: [MIDINote] = [], duration = 0.0
        for index in 0..<count {
            var track: MusicTrack?
            var iterator: MusicEventIterator?
            guard MusicSequenceGetIndTrack(source, index, &track) == noErr, let track,
                  NewMusicEventIterator(track, &iterator) == noErr, let iterator else { continue }
            defer { DisposeMusicEventIterator(iterator) }
            var hasEvent = DarwinBoolean(false)
            while MusicEventIteratorHasCurrentEvent(iterator, &hasEvent) == noErr, hasEvent.boolValue {
                var beat: MusicTimeStamp = 0, kind: MusicEventType = 0, size: UInt32 = 0
                var data: UnsafeRawPointer?
                MusicEventIteratorGetEventInfo(iterator, &beat, &kind, &data, &size)
                if kind == kMusicEventType_MIDINoteMessage, let data, size >= MemoryLayout<MIDINoteMessage>.size {
                    let note = data.load(as: MIDINoteMessage.self)
                    var begin = 0.0, end = 0.0
                    if note.velocity > 0, MusicSequenceGetSecondsForBeats(source, beat, &begin) == noErr,
                       MusicSequenceGetSecondsForBeats(source, beat + Double(note.duration), &end) == noErr,
                       begin.isFinite, end.isFinite, begin >= 0, end > begin {
                        notes.append(.init(start: begin * 2, length: (end - begin) * 2, pitch: Int(note.note),
                                           velocity: Int(note.velocity), channel: Int(note.channel) + 1))
                        duration = max(duration, end)
                    }
                }
                MusicEventIteratorNextEvent(iterator)
            }
        }
        guard !notes.isEmpty else { throw ProjectError.invalid("The MIDI file contains no notes.") }
        var item = AudioClip(id: UUID(), name: url.deletingPathExtension().lastPathComponent, startTime: start, duration: duration)
        item.midi = MIDIItem(notes: notes)
        return item
    }
    #endif
    func browsePortablePackage() {
        guard !busy, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        #if os(macOS)
        guard confirmPortableImportPrompt(.file) else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "ziplive") ?? .zip, .zip]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.title = JarasLocalization.string("Choose a CatLive project")
        if panel.runModal() == .OK, let url = panel.url { importPortablePackage(url) }
        #else
        guard nativePicker == nil, nativePackagePrompt == nil, nativePendingPackage == nil else { return }
        cancelNativePackageImport()
        nativePackagePrompt = .file
        #endif
    }
    func chooseStems(adding: Bool) {
        guard !busy, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
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
        #else
        clearImportSelection()
        self.adding = adding
        appendDestination = adding ? currentURL.map { (project: show.snapshot.project.id, url: $0) } : nil
        nativePicker = .stems
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
        #if os(iOS)
        for url in nativeScopedFolders { url.stopAccessingSecurityScopedResource() }
        nativeScopedFolders = []
        #endif
        scan = nil; folderReview = nil; folderSelectionRoot = nil; folders = []; selectedFolders = []
        removal = ""; adding = false; appendDestination = nil
    }
    private func localizedStemWarning(_ warning: String) -> String {
        let projectSuffix = ": contains a CatLive project"
        if warning.hasSuffix(projectSuffix) {
            return String(format: JarasLocalization.string("%@ contains a CatLive project. Use Open existing and select the .jl file inside the folder."),
                          String(warning.dropLast(projectSuffix.count)))
        }
        let suffix = ": no readable WAV, AIFF or MP3 files"
        guard warning.hasSuffix(suffix) else { return warning }
        return String(format: JarasLocalization.string("%@ contains no readable WAV, AIFF or MP3 files. Open the folder and select the song folders containing audio."), String(warning.dropLast(suffix.count)))
    }
    private func analyzeFolders(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        busy = true; error = ""; warnings = []; status = "Analyzing audio and names…"
        Task {
            defer { busy = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) { try StemProjectImporter.scan(urls) }.value
                scan = result; removal = ""; warnings = result.warnings.map(localizedStemWarning)
            } catch { self.error = error.localizedDescription.components(separatedBy: "\n").map(localizedStemWarning).joined(separator: "\n") }
        }
    }
    func discardTemporarySession() throws {
        guard let temporarySession else { return }
        try temporarySession.discard()
        self.temporarySession = nil
    }
    func createTemporary(fromFileMenu: Bool = false) {
        guard show.canControl(), !busy, !importingAudio, !show.saving,
              !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        if isTemporary {
            error = ""; opened = UUID(); return
        }
        busy = true; error = ""
        Task {
            defer { busy = false; status = "" }
            do {
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let lease = try await Task.detached(priority: .userInitiated) {
                    try TemporaryProjectSession(documents: documents)
                }.value
                temporarySession = lease
                let url = lease.directory.appendingPathComponent("Temporary.jl")
                var project = Project.empty(name: JarasLocalization.string("Temporary"))
                GlobalProjectTiming.load()?.apply(to: &project)
                project.projectSyncID = UUID()
                try ProjectDocumentCodec.writeEncoded(ProjectDocumentCodec.encode(project), to: url, exclusive: true)
                try await activate(project, at: url)
            } catch is CancellationError {
                if !isTemporary { try? discardTemporarySession() }
            } catch {
                if !isTemporary { try? discardTemporarySession() }
                self.error = error.localizedDescription
                if fromFileMenu { show.modalNotice = self.error }
            }
        }
    }
    private func saveTemporary() async {
        guard isTemporary, !busy, !importingAudio, !show.saving,
              !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = JarasLocalization.string("Save Project")
        panel.allowedContentTypes = [UTType(filenameExtension: "jl") ?? .data]
        panel.nameFieldStringValue = "Untitled.jl"; panel.canCreateDirectories = true
        let accepted: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let window = NSApp.keyWindow { panel.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
            else { panel.begin { continuation.resume(returning: $0) } }
        }
        guard accepted == .OK, let selected = panel.url, isTemporary else { return }
        let name = selected.deletingPathExtension().lastPathComponent
        // Always own a new directory: a failed promotion cannot remove existing files.
        let destination = ProjectDirectoryPolicy.availableFolder(named: name, in: selected.deletingLastPathComponent())
            .appendingPathComponent(name).appendingPathExtension("jl")
        await promoteTemporary(to: destination)
        #else
        nativeProjectName = ""; nativePendingCreation = nil; nativeNamePrompt = true
        #endif
    }
    #if os(iOS)
    private func receiveTemporaryDestination(_ root: URL) {
        guard isTemporary else { return }
        let scoped = root.startAccessingSecurityScopedResource()
        let name: String
        do { name = try ProjectName.validated(nativeProjectName) }
        catch { if scoped { root.stopAccessingSecurityScopedResource() }; self.error = error.localizedDescription; return }
        Task {
            let destination = ProjectDirectoryPolicy.availableFolder(named: name, in: root)
                .appendingPathComponent(name).appendingPathExtension("jl")
            await promoteTemporary(to: destination)
            if currentURL == destination {
                if scoped { nativeStorageScopes.append(root) }
                if let bookmark = try? root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    var bookmarks = UserDefaults.standard.array(forKey: "jaras.nativeImportedProjectBookmarks") as? [Data] ?? []
                    bookmarks.append(bookmark); UserDefaults.standard.set(bookmarks, forKey: "jaras.nativeImportedProjectBookmarks")
                }
            } else if scoped { root.stopAccessingSecurityScopedResource() }
        }
    }
    #endif
    private func promoteTemporary(to destination: URL) async {
        guard isTemporary, let lease = temporarySession, !busy, !importingAudio,
              !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        busy = true; error = ""; status = "Copying audio and saving project…"
        let operation = UUID()
        temporarySaveOperation = operation; temporarySaveProgress = .preparing
        let canExecute = show.canExecute; show.canExecute = { false }
        defer {
            temporarySaveOperation = nil; temporarySaveProgress = nil
            busy = false; status = ""; show.canExecute = canExecute
        }
        do {
            closeProjectEditors()
            try await show.flushProject()
            guard let saved = try await store.load() else { throw ProjectError.invalid("Project not found") }
            let result = try await Task.detached(priority: .userInitiated) {
                try lease.export(saved, to: destination) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.temporarySaveOperation == operation,
                              progress.sequence >= (self.temporarySaveProgress?.sequence ?? 0) else { return }
                        self.temporarySaveProgress = progress
                    }
                }
            }.value
            try await activate(result, at: destination)
            show.message = "Projeto salvo."
        } catch { self.error = error.localizedDescription; show.modalNotice = error.localizedDescription }
    }

    /// Completes only after activation/media preparation, or after recovery is
    /// resolved. A batch must never start its next tab while this one is loading.
    func waitUntilOpened(at url: URL) async throws {
        await Task.yield()
        while busy || missingAudioPrompt != nil {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        guard ready, currentURL?.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() else {
            throw ProjectError.invalid(error.isEmpty ? "Could not open project." : error)
        }
    }
    func openMultipleProjects(_ urls: [URL]) {
        guard !busy, !urls.isEmpty, let openProjectTabAndWait else { return }
        MultipleProjectOpening.shared.open(urls) { [weak self] url in
            guard let self else { throw CancellationError() }
            if !self.ready {
                self.open(url)
                try await self.waitUntilOpened(at: url)
            } else { try await openProjectTabAndWait(url) }
        }
    }

    func createEmpty() { finish(scan: nil, detectBPM: false) }
    #if os(macOS)
    func createEmptyInNewTab() -> Bool {
        guard ready, show.canControl(), !busy, !TrackRecording.shared.recording,
              !TrackRecording.shared.busy, let openInNewProjectTab else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "jl") ?? .data]
        panel.nameFieldStringValue = "Untitled.jl"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let selected = panel.url else { return false }
        let url = ProjectDirectoryPolicy.newProjectDestination(for: selected)
        do {
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw ProjectError.invalid("A project already exists at this location. Choose another name.")
            }
            try ProjectDirectoryPolicy.validate(url)
            var project = Project.empty(name: url.deletingPathExtension().lastPathComponent)
            GlobalProjectTiming.load()?.apply(to: &project)
            project.projectSyncID = UUID()
            let data = try ProjectDocumentCodec.encode(project)
            try ProjectDirectoryPolicy.prepareNewProjectDirectory(for: url)
            try ProjectDocumentCodec.writeEncoded(data, to: url, exclusive: true)
            openInNewProjectTab(url)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    #endif
    func createRecordingProject(channels: Int) {
        guard (1...128).contains(channels) else { error = "Choose between 1 and 128 channels."; return }
        finish(scan: nil, detectBPM: false, recordingChannels: channels)
    }
    func confirmImport(detectBPM: Bool) { guard let scan else { return }; finish(scan: scan, detectBPM: detectBPM) }
    private func finish(scan: StemScan?, detectBPM: Bool, recordingChannels: Int? = nil) {
        guard show.canControl(), !busy, !TrackRecording.shared.recording, !TrackRecording.shared.busy else { return }
        #if os(iOS)
        if !(scan != nil && adding) {
            // Choose storage before showing the name alert. Presenting Files
            // from the alert's button can leave its keyboard window in charge
            // while Files tries to focus its new-folder rename field.
            guard nativeStorageDirectory != nil else {
                afterNativeStorage = { [weak self] in self?.finish(scan: scan, detectBPM: detectBPM, recordingChannels: recordingChannels) }
                nativePicker = .storage; return
            }
            nativePendingCreation = (scan, detectBPM, recordingChannels); nativeProjectName = ""; nativeNamePrompt = true; return
        }
        #endif
        finish(scan: scan, detectBPM: detectBPM, destination: nil, recordingChannels: recordingChannels)
    }
    private func finish(scan: StemScan?, detectBPM: Bool, destination: URL?, recordingChannels: Int? = nil) {
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
            #if os(macOS)
            let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "jl") ?? .data]
            panel.nameFieldStringValue = "Untitled.jl"; panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let selected = panel.url else { return }
            url = ProjectDirectoryPolicy.newProjectDestination(for: selected)
            #else
            guard let destination else { return }
            url = destination
            #endif
            guard !FileManager.default.fileExists(atPath: url.path) else { error = "A project already exists at this location. Choose another name."; return }
        }
        do { try ProjectDirectoryPolicy.validate(url) }
        catch { self.error = error.localizedDescription; return }
        let remove = removal
        busy = true; error = ""; status = "Copying audio and saving project…"
        let canExecute = show.canExecute
        show.canExecute = { false }
        Task {
            defer { show.canExecute = canExecute; busy = false }
            do {
                // Flush the previous document before replacing it or appending media.
                closeProjectEditors()
                if ready && append {
                    // Cursor-only changes also belong in the appended document.
                    try await show.flushProject()
                    guard !show.hasUnsavedChanges else {
                        throw ProjectError.invalid("The project changed while saving. Save again before closing.")
                    }
                } else { try await confirmOutgoingProject() }
                var base: Project
                if append {
                    // Use the committed copy: it contains captured plugin state,
                    // automation and cursor metadata not all present in snapshot.
                    guard let saved = try await store.load(), let destination = appendDestination,
                          saved.id == destination.project, show.snapshot.project.id == destination.project,
                          currentURL == destination.url, currentURL == url, !show.hasUnsavedChanges else {
                        throw ProjectError.invalid("The open project changed. Start Add Project again.")
                    }
                    base = saved
                } else if let recordingChannels {
                    base = try Project.recordingMultitrack(name: url.deletingPathExtension().lastPathComponent,
                        channels: recordingChannels, trackPrefix: JarasLocalization.string("Track"))
                } else { base = Project.empty(name: url.deletingPathExtension().lastPathComponent) }
                if !append { GlobalProjectTiming.load()?.apply(to: &base) }
                let importBase = base
                let result = try await Task.detached(priority: .userInitiated) {
                    if append { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
                    else { try ProjectDirectoryPolicy.prepareNewProjectDirectory(for: url) }
                    var readWarnings: [String] = []
                    var project = try scan.map { try StemProjectImporter.build(scan: $0, remove: remove, base: importBase, destination: url, progress: { [weak self] current, total, name in
                        Task { @MainActor [weak self] in self?.status = "Importing \(current)/\(total): \(name)" }
                    }, onUnreadable: { _, _ in }) } ?? importBase
                    if project.projectSyncID == nil { project.projectSyncID = UUID() }
                    var tempoWarnings: [String] = []
                    do {
                    if detectBPM, scan != nil, !project.songs.isEmpty {
                        Task { @MainActor [weak self] in self?.status = "Detecting BPM…" }
                        var song = project.songs[0]
                        let existingRegions = Set(importBase.songs.flatMap(\.parts).map(\.id))
                        let directory = url.deletingLastPathComponent()
                        for region in song.parts where !existingRegions.contains(region.id) && region.parentRegionID == nil {
                            try Task.checkCancellation()
                            if song.markers?.contains(where: { $0.isTempo && $0.regionOwnerID == region.id }) == true { continue }
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
                    return (project, readWarnings + tempoWarnings)
                    } catch {
                        let existing = Set(importBase.songs.flatMap(\.tracks).flatMap(\.clips).compactMap { $0.audioFile?.path })
                        let imported = project.songs.flatMap(\.tracks).flatMap(\.clips).compactMap { $0.audioFile?.path }.filter { !existing.contains($0) }
                        for folder in Set(imported.map { url.deletingLastPathComponent().appendingPathComponent($0).deletingLastPathComponent() }) { try? FileManager.default.removeItem(at: folder) }
                        throw error
                    }
                }.value
                if currentURL != url { try await rememberProjectMedia() }
                // The new file is already saved. Do not save the old snapshot
                // over it, or redirect later saves if backend activation fails.
                await preloadTimelineWaveforms(result.0, at: url)
                if append {
                    // Appending is an edit of the live session, not a project load.
                    // Retain transport, voices, record arms and viewport state.
                    try show.applyImportedProject(result.0)
                    await store.select(url: url, savedProject: result.0)
                } else {
                    show.send(.stopAll)
                    try show.replaceProject(result.0)
                    resetProjectSelections()
                    await store.select(url: url, savedProject: result.0)
                    try await projectAudio.openPreparedProject(directory: url.deletingLastPathComponent(), project: show.snapshot.project)
                    VideoPlayback.shared.open(directory: url.deletingLastPathComponent())
                    VideoPlayback.teleprompter.open(directory: url.deletingLastPathComponent())
                    VideoPlayback.teleprompter2.open(directory: url.deletingLastPathComponent())
                    #if os(macOS)
                    TeleprompterRemote.setProjectDirectory(url.deletingLastPathComponent())
                    #endif
                    VideoPlayback.shared.update(show.snapshot, revision: show.projectRevision)
                    TrackRecording.shared.open(directory: url.deletingLastPathComponent(), project: show.snapshot.project.id)
                    if recordingChannels != nil {
                        TrackRecording.shared.setArmed(Set(result.0.songs.flatMap(\.tracks).map(\.id)), active: true, requiresAudioInput: true)
                    }
                    show.preparePlayback()
                    opened = UUID()
                }
                currentURL = url; remember(url); ready = true; clearImportSelection()
                warnings += result.1
                completedStemImport = UUID()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct MissingAudioRecoveryView: View {
    @ObservedObject var documents: ProjectDocuments
    @State private var choosingFolder = false
    var body: some View {
        if let prompt = documents.missingAudioPrompt {
            MissingAudioRecoveryPanel(paths: prompt.paths, warnings: documents.warnings, errors: prompt.errors,
                busy: documents.busy, status: documents.status, canCancel: !documents.busy || documents.canCancelOpening,
                cancel: { documents.cancelMissingAudioOpen() },
                open: { documents.openWithMissingAudio() }, search: { choosingFolder = true })
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


/// File names and import warnings share one bounded viewport. Neither long
/// reports nor file-search errors may push the actions below the screen.
struct MissingAudioRecoveryPanel: View {
    let paths: [String], warnings: [String], errors: [String]
    let busy: Bool
    let status: String
    let canCancel: Bool
    let cancel: () -> Void, open: () -> Void, search: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Missing audio files").font(.jarasHeadline)
                Text(String(format: JarasLocalization.string(paths.count == 1 ? "%d audio file is missing" : "%d audio files are missing"), paths.count))
                    .font(.jarasCallout).foregroundStyle(JarasTheme.secondary)
            }.accessibilityIdentifier("missing-audio-header")
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                        Text(verbatim: path).font(.jarasSystem(.caption, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6).background(JarasTheme.panel).jarasHelp(path)
                    }
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                        Text(verbatim: warning).font(.jarasSystem(size: 12)).foregroundStyle(JarasTheme.yellow)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.disabled)
                    }
                    ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                        Text(verbatim: error).font(.jarasCaption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(10)
            }
            .modifier(ImportReportScrollIndicators())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(JarasTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("missing-audio-details")
            if busy { HStack { ProgressView().controlSize(.small); Text(LocalizedStringKey(status)) }.font(.jarasCaption).lineLimit(1) }
            HStack(spacing: 10) {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).disabled(!canCancel)
                Spacer(minLength: 0)
                Button("Open anyway", action: open).keyboardShortcut(.defaultAction).disabled(busy)
                Button("Search", action: search).disabled(busy)
                    .buttonStyle(StageButtonStyle(color: JarasTheme.green))
            }.font(.jarasSystem(size: 12)).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("missing-audio-actions")
        }
        .padding(20).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
        .frame(minWidth: 320, idealWidth: 560, maxWidth: 560,
               minHeight: 240, idealHeight: 440, maxHeight: 440)
    }
}
private struct ImportReportScrollIndicators: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 13, iOS 16, *) { content.scrollIndicators(.visible) }
        else { content }
    }
}

struct ProjectBrowserNavigation: Equatable {
    private let id = UUID()
    let recents: Bool
}

struct ProjectBrowserView: View {
    @AppStorage(JarasInterfaceTheme.preferenceKey) private var interfaceTheme = JarasInterfaceTheme.defaultTheme
    @ObservedObject var documents: ProjectDocuments
    var completed: () -> Void = {}
    var homeModal = false
    var returnToProject: (() -> Void)? = nil
    var navigation: ProjectBrowserNavigation? = nil
    @State private var creating = false
    @State private var addingOptions = false
    @State private var opening = false
    @State private var recentSearch = ""
    @State private var recentToOpen: URL?
    @State private var selectingMultipleProjects = false
    @State private var recentStorage: [URL: String] = [:]
    private var filteredRecent: [URL] { documents.recent.filter { RecentProjectEntry.matches($0, query: recentSearch) } }
    @State private var askingForBPM = false
    @State private var recordingSetup = false
    @State private var recordingChannelCount = 32
    #if os(iOS)
    #endif
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
            if let root = documents.folderSelectionRoot {
                #if os(iOS)
                NativeStemFolderBrowser(root: root, cancel: documents.cancelImport, confirm: documents.confirmNativeStemFolders)
                #endif
            } else if let folders = documents.folderReview {
                FolderImportReview(folders: folders, selectedFolders: documents.selectedFolders, appending: documents.adding,
                                   cancel: documents.cancelImport, confirm: documents.confirmFolders)
            } else if let scan = documents.scan {
                #if os(iOS)
                NativeStemImportReview(documents: documents, scan: scan)
                #else
                Text("Review stems").font(.jarasTitle3.bold())
                Text("\(scan.folders.count) song folders · \(scan.folders.reduce(0) { $0 + $1.files.count }) audio files").font(.jarasCaption)
                if !scan.suggestions.isEmpty {
                    Text("Repeated names were found that may identify providers. Select suggestions or type names to remove.").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
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
                Text("Original folders remain unchanged. Audio is copied beside the .jl project.").font(.jarasCaption2).foregroundStyle(JarasTheme.secondary)
                HStack { Button("Back", action: documents.reviewFolderOrder); Spacer(); Button("Create / Add") { askingForBPM = true }.buttonStyle(StageButtonStyle(color: JarasTheme.green)).keyboardShortcut(.defaultAction) }
                #endif
            } else {
                HStack {
                    Text("CatLive").font(.jarasTitle2.bold())
                    if let returnToProject {
                        Spacer()
                        Button("Back to project", action: returnToProject)
                            .disabled(documents.busy).keyboardShortcut(.cancelAction)
                    }
                }
                #if os(iOS)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                    startupCard("Create Project", icon: "plus.rectangle", color: JarasTheme.green) { creating.toggle(); opening = false; addingOptions = false }
                    addProjectButton
                    startupCard(homeModal ? "Recents" : "Recent Projects", icon: "folder", color: JarasTheme.purple) { opening = true; creating = false; addingOptions = false }
                }.padding(.vertical, 12)
                #else
                HStack(spacing: 10) {
                    action("Create Project", icon: "plus.rectangle") { creating.toggle(); opening = false; addingOptions = false }
                    addProjectButton
                    action(homeModal ? "Recents" : "Recent Projects", icon: "folder") { opening = true; creating = false; addingOptions = false }
                }
                #endif
                #if os(iOS)
                HStack {
                    recentAction("Project folder", icon: "externaldrive") { documents.chooseNativeStorage() }
                    Spacer()
                    Text(documents.nativeStorageDirectory == nil ? "Choose an external folder" : "External folder selected")
                        .font(.jarasCaption).foregroundStyle(documents.nativeStorageDirectory == nil ? JarasTheme.yellow : JarasTheme.green)
                }
                if documents.nativeStorageDirectory == nil {
                    if documents.nativeStorageNeedsAccess {
                        Text("Choose the external project folder again to restore access.")
                            .font(.jarasCaption).foregroundStyle(JarasTheme.yellow)
                    } else {
                        Text("Choose a folder outside CatLive to keep projects and media after deleting the app. Existing projects will be copied there.")
                            .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                    }
                }
                #endif
                if creating {
                    if recordingSetup {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("REC Multitrack").font(.jarasHeadline)
                            HStack(spacing: 10) {
                                Text("Channels")
                                TextField("Channels", value: $recordingChannelCount, formatter: NumberFormatter())
                                    .textFieldStyle(.roundedBorder).frame(width: 64)
                                Stepper("Channels", value: $recordingChannelCount, in: 1...128).labelsHidden().fixedSize()
                                Spacer()
                            }
                            Text("Mono inputs in sequence, all tracks armed, monitoring on.")
                                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                            HStack {
                                Button("Back") { recordingSetup = false }
                                Spacer()
                                Button("Create Project") { documents.createRecordingProject(channels: recordingChannelCount) }
                                    .buttonStyle(StageButtonStyle(color: JarasTheme.green))
                                    .disabled(!(1...128).contains(recordingChannelCount))
                                    .keyboardShortcut(.defaultAction)
                            }
                        }.padding(14).background(JarasTheme.panel).cornerRadius(8)
                    } else {
                        VStack(spacing: 8) {
                            HStack {
                                action("Add Stems", icon: "waveform") { documents.chooseStems(adding: false) }
                                action("Empty", icon: "doc") { documents.createEmpty() }
                                    #if os(macOS)
                                    .contextMenu {
                                        if documents.ready, documents.openInNewProjectTab != nil {
                                            Button("Open in new tab") {
                                                if documents.createEmptyInNewTab() { completed() }
                                            }
                                        }
                                    }
                                    #endif
                                action("REC Multitrack", icon: "record.circle") { recordingSetup = true }
                            }
                            action("Temporary", icon: "clock") { documents.createTemporary() }
                            HStack {
                                action("REAPER", icon: "waveform.path") { documents.chooseMigration("rpp") }
                                action("Logic", icon: "pianokeys") { documents.chooseMigration("logicx") }
                            }
                        }
                    }
                }
                if addingOptions {
                    HStack(spacing: 10) {
                        action("Add Stems", icon: "waveform") { documents.chooseStems(adding: true) }
                            .accessibilityIdentifier("project-add-stems")
                        action("Add .ziplive", icon: "doc.zipper") { documents.browsePortablePackage() }
                            .accessibilityIdentifier("project-add-ziplive")
                    }
                }
                if opening {
                HStack {
                    Text("Recent projects").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                    Spacer()
                    #if os(iOS)
                    recentAction("Open multiple projects") { selectingMultipleProjects = true }
                        .disabled(documents.recent.isEmpty || documents.openProjectTabAndWait == nil)
                    recentAction("Open existing") { documents.browse() }
                    #else
                    Button("Open multiple projects") { selectingMultipleProjects = true }
                        .disabled(documents.recent.isEmpty || documents.openProjectTabAndWait == nil)
                    Button("Open existing") { documents.browse() }
                    #endif
                }
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
                            Button {
                                if documents.ready && documents.currentURL?.standardizedFileURL != url.standardizedFileURL {
                                    recentToOpen = url
                                } else {
                                    documents.open(url)
                                    if documents.ready, returnToProject != nil { completed() }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(url.deletingPathExtension().lastPathComponent).font(.jarasBody.bold())
                                        #if os(macOS)
                                        Text(url.deletingLastPathComponent().path).font(.jarasCaption2).foregroundStyle(JarasTheme.secondary).lineLimit(1)
                                        #endif
                                    }
                                    Spacer()
                                    Text(recentStorage[url] ?? NSLocalizedString("Calculating…", comment: "Project storage size")).font(.jarasCaption)
                                        .foregroundStyle(JarasTheme.secondary).fixedSize()
                                        .accessibilityLabel(Text("Project size") + Text(": " + (recentStorage[url] ?? NSLocalizedString("Calculating…", comment: "Project storage size"))))
                                    Image(systemName: "chevron.right")
                                }
                                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(JarasTheme.panel).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .contextMenu {
                                    #if os(macOS)
                                    Button("Open project location") {
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    }.disabled(RecentProjectEntry.isMissing(url))
                                    #endif
                                    if documents.ready, !RecentProjectEntry.isMissing(url), documents.openInNewProjectTab != nil {
                                        Button("Open in new tab") { documents.openInNewProjectTab?(url); completed() }
                                    }
                                    Button(role: .destructive) { documents.requestDeletion(url) } label: {
                                        Label(RecentProjectEntry.isMissing(url) ? "Remove from recents" : "Delete project", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }.frame(maxHeight: 170)
                    .task(id: documents.recent) {
                        for url in documents.recent {
                            let bytes = try? await ProjectOpeningWork.run {
                                let access = url.startAccessingSecurityScopedResource()
                                defer { if access { url.stopAccessingSecurityScopedResource() } }
                                return try RecentProjectStorage.bytes(at: url)
                            }
                            guard !Task.isCancelled else { return }
                            recentStorage[url] = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
                        }
                    }
                if filteredRecent.isEmpty { Text("No recent projects found.").font(.jarasCaption).foregroundStyle(JarasTheme.secondary) }
                }
            }
            }.disabled(documents.busy)
            if !documents.warnings.isEmpty && !nativeReviewVisible { Text(documents.warnings.joined(separator: "\n")).font(.jarasCaption).foregroundStyle(JarasTheme.yellow).lineLimit(3).jarasHelp(documents.warnings.joined(separator: "\n")) }
            if !documents.error.isEmpty { Text(LocalizedStringKey(documents.error)).font(.jarasCaption).foregroundStyle(.red).textSelection(.disabled) }
            if documents.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(LocalizedStringKey(documents.status)).font(.jarasCaption)
                    Spacer()
                    if documents.canCancelOpening {
                        Button("Cancel") { documents.cancelOpening() }.keyboardShortcut(.cancelAction)
                    }
                }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(interfaceTheme.homeBackground).foregroundStyle(JarasTheme.text)
            .onChange(of: navigation) { request in
                if let request {
                    opening = request.recents; creating = false; addingOptions = false
                }
            }
            .onChange(of: documents.opened) { _ in
                if !documents.ready { opening = false; creating = false; addingOptions = false }
                completed()
            }
            .onChange(of: documents.completedStemImport) { _ in completed() }
            // Recovery is presented by the session root. Release the browser
            // sheet first so its missing-media sheet is not queued underneath
            // Recent Projects while the old workspace is still open.
            .onChange(of: documents.missingAudioPrompt?.id) { id in
                if id != nil { completed() }
            }
            .onChange(of: creating) { _ in recordingSetup = false }
            .sheet(isPresented: $selectingMultipleProjects) {
                RecentMultipleProjectPicker(urls: documents.recent, cancel: { selectingMultipleProjects = false }) { urls in
                    selectingMultipleProjects = false
                    completed()
                    documents.openMultipleProjects(urls)
                }
            }
            .sheet(item: $documents.pendingDeletion) { deletion in
                ProjectDeletionConfirmation(documents: documents, prompt: deletion)
            }
            .alert("Open another project?", isPresented: Binding(get: { recentToOpen != nil }, set: { if !$0 { recentToOpen = nil } }), presenting: recentToOpen) { url in
                Button("Cancel", role: .cancel) { recentToOpen = nil }
                Button("Open project") { recentToOpen = nil; documents.open(url) }
            } message: { url in
                Text("The current project will be replaced by \(url.deletingPathExtension().lastPathComponent).")
            }
            .alert("Open a project first", isPresented: $documents.showingOpenProjectAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Open a project before using Add Project.")
            }
            #if os(macOS)
            .confirmationDialog("Detect BPM for each song?", isPresented: $askingForBPM, titleVisibility: .visible) {
                Button("Yes") { documents.confirmImport(detectBPM: true) }
                Button("No") { documents.confirmImport(detectBPM: false) }
            }
            #endif
    }
    private var nativeReviewVisible: Bool {
        #if os(iOS)
        return documents.scan != nil
        #else
        return false
        #endif
    }
    private var addProjectButton: some View {
        Button {
            addingOptions.toggle(); creating = false; opening = false
        } label: {
            #if os(iOS)
            startupCardLabel(homeModal ? "Add Projects" : "Add Project", icon: "folder.badge.plus", color: JarasTheme.purple)
            #else
            Label(homeModal ? LocalizedStringKey("Add Projects") : LocalizedStringKey("Add Project"), systemImage: "folder.badge.plus")
                .font(.jarasSystem(size: 12, weight: .medium)).frame(maxWidth: .infinity, minHeight: 38)
                .background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
            #endif
        }.buttonStyle(.plain)
    }
    private func action(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(LocalizedStringKey(title), systemImage: icon).font(.jarasSystem(size: 12, weight: .medium)).frame(maxWidth: .infinity, minHeight: 38).background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
    #if os(iOS)
    private func recentAction(_ title: LocalizedStringKey, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let icon { Label(title, systemImage: icon) }
                else { Text(title) }
            }
                .font(.jarasSystem(size: 12, weight: .semibold))
                .padding(.horizontal, 12).frame(minHeight: 34)
                .background(JarasTheme.panel, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(JarasTheme.secondary.opacity(0.75)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func startupCard(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { startupCardLabel(title, icon: icon, color: color) }.buttonStyle(.plain)
    }
    private func startupCardLabel(_ title: String, icon: String, color: Color) -> some View {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: icon).font(.jarasSystem(size: 30, weight: .medium)).foregroundStyle(color)
                HStack {
                    Text(LocalizedStringKey(title)).font(.jarasSystem(size: 17, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.jarasSystem(size: 12, weight: .semibold)).foregroundStyle(JarasTheme.secondary)
                }
            }.padding(20).frame(maxWidth: .infinity, minHeight: 146, alignment: .leading)
                .background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.3)))
                .contentShape(RoundedRectangle(cornerRadius: 12))
    }
    #endif
}

private struct ProjectDeletionConfirmation: View {
    @ObservedObject var documents: ProjectDocuments
    let prompt: ProjectDeletionPrompt
    private var deletion: ProjectFolderDeletion? { documents.pendingDeletion?.plan }
    @State private var remaining = 3
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Delete project", systemImage: "trash").font(.jarasTitle3.bold()).foregroundStyle(.red)
            Text(verbatim: prompt.document.deletingPathExtension().lastPathComponent).font(.jarasHeadline)
            if let deletion {
            Text(LocalizedStringKey(deletion.deletesDirectory
                 ? "The entire project folder and everything inside it will be permanently deleted, including media, presets, waveform caches, backups and unused files. This cannot be undone."
                 : "The CatLive project and its own media, waveform caches and backups will be permanently deleted. The containing folder, unrelated files and media shared with other projects will be kept. This cannot be undone.")).font(.jarasBody)
            Text(verbatim: deletion.target.path).font(.jarasCaption).textSelection(.disabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(JarasTheme.display).cornerRadius(5)
            } else if documents.error.isEmpty {
                ProgressView("Preparing project deletion…")
            }
            if !documents.error.isEmpty { Text(LocalizedStringKey(documents.error)).font(.jarasCaption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { documents.pendingDeletion = nil }.keyboardShortcut(.cancelAction).disabled(documents.busy)
                Spacer()
                if documents.busy { ProgressView().controlSize(.small) }
                Button(role: .destructive) { if let deletion { documents.deleteProject(deletion) } } label: {
                    if remaining > 0 { Text("Delete in \(remaining)s") } else { Text("Delete project") }
                }.buttonStyle(StageButtonStyle(color: .red)).disabled(remaining > 0 || deletion == nil || documents.busy)
            }
        }.padding(24).frame(width: 460).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .interactiveDismissDisabled(documents.busy)
            .task {
                remaining = prompt.remainingSeconds
                while remaining > 0, !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    remaining = prompt.remainingSeconds
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
            if let version = accessory.view as? ProjectTitlebarVersionView {
                return version.containsUpdateButton(at: version.convert(point, from: nil))
            }
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

private final class ProjectTitlebarVersionView: NSView, DesktopUpdateNoticeObserver {
    static let text = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        .map { text(for: $0) } ?? "CatLive"
    static func text(for version: String) -> String {
        let components = version.split(separator: ".")
        guard components.count >= 2, let major = Int(components[0]), let minor = Int(components[1]) else {
            return "CatLive Version " + version
        }
        return "CatLive Version " + String(major) + "." + String(format: "%02d", minor)
    }
    private let label = NSTextField(labelWithString: text)
    private let updateButton = NSButton(title: "Update", target: nil, action: nil)
    private var updateURL: URL?
    private let openURL: (URL) -> Void
    var widthChanged: (() -> Void)?
    var preferredWidth: CGFloat { ceil(label.intrinsicContentSize.width) + 20 + (updateURL == nil ? 0 : 68) }
    init(service: DesktopUpdateNoticeService? = nil, startsService: Bool = true,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.openURL = openURL
        super.init(frame: NSRect(x: 0, y: 0, width: 160, height: 22))
        label.font = .jarasSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.alignment = .right
        label.lineBreakMode = .byClipping
        addSubview(label)
        updateButton.font = .jarasSystemFont(ofSize: 11, weight: .semibold)
        updateButton.isBordered = false
        updateButton.contentTintColor = .black
        updateButton.wantsLayer = true
        updateButton.layer?.backgroundColor = NSColor.systemYellow.cgColor
        updateButton.layer?.cornerRadius = 4
        updateButton.target = self; updateButton.action = #selector(openUpdate)
        updateButton.setAccessibilityLabel("Update")
        updateButton.isHidden = true
        addSubview(updateButton)
        let service = service ?? DesktopUpdateNoticeService.shared
        service.observe(self)
        if startsService { service.start() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let height = min(bounds.height, ceil(label.intrinsicContentSize.height))
        let offset: CGFloat = updateURL == nil ? 0 : 68
        label.frame = NSRect(x: 6 + offset, y: floor((bounds.height - height) / 2), width: max(0, bounds.width - 16 - offset), height: height)
        updateButton.frame = NSRect(x: 6, y: floor((bounds.height - 18) / 2), width: 60, height: 18)
    }
    func desktopUpdateNoticeChanged(_ notice: DesktopUpdateNotice?) {
        let wasVisible = updateURL != nil
        updateURL = notice?.url
        updateButton.isHidden = notice == nil
        updateButton.toolTip = notice.map { "CatLive " + $0.version }
        if wasVisible != (notice != nil) { needsLayout = true; widthChanged?() }
    }
    @objc private func openUpdate() { if let updateURL { openURL(updateURL) } }
    func containsUpdateButton(at point: NSPoint) -> Bool { !updateButton.isHidden && updateButton.frame.contains(point) }
    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard containsUpdateButton(at: local) else { return nil }
        return updateButton
    }
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
        version.widthChanged = { [weak self] in self?.updateWidths() }
        leading.layoutAttribute = .left; leading.view = host; leading.interactive = true
        trailing.layoutAttribute = .right; trailing.view = version; trailing.interactive = true
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
    var login = false
    let documents: ProjectDocuments
    var chromeColor = JarasTheme.titlebar
    @AppStorage(InterfaceScale.key) private var interfaceScale = 1.0
    func makeNSView(context: Context) -> ProjectWindowAnchor {
        let view = ProjectWindowAnchor()
        configure(view)
        return view
    }
    func updateNSView(_ view: ProjectWindowAnchor, context: Context) {
        configure(view)
        view.update()
    }
    private func configure(_ view: ProjectWindowAnchor) {
        view.editor = editor; view.login = login; view.documents = documents
        view.interfaceScale = CGFloat(InterfaceScale.factor(interfaceScale))
        view.titlebarColor = NSColor(chromeColor)
    }
}
// The native window already has explicit editor/browser bounds. Do not ask
// SwiftUI to measure its entire document again for minimum, ideal and maximum
// window sizes on every frame of a live resize.
private protocol ProjectFrameSizedHosting: AnyObject {
    func useProjectWindowFrame()
}
extension NSHostingView: ProjectFrameSizedHosting {
    fileprivate func useProjectWindowFrame() {
        if #available(macOS 13, *) { sizingOptions = [] }
    }
}
final class ProjectWindowAnchor: NSView {
    private static weak var editorWindow: NSWindow?
    static func toggleFullscreen() {
        guard let window = editorWindow, window.isVisible, window.attachedSheet == nil else { return }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toggleFullScreen(nil)
    }
    static let editorFrameSize = NSSize(width: 1440, height: 791)
    static let editorMinimumFrameSize = NSSize(width: 1162, height: 757)
    static func configureChrome(of window: NSWindow) {
        // The interface already stays below the native titlebar. Extending its
        // host underneath it makes AppKit walk every control's drag-prevention
        // region whenever a sidebar changes width.
        window.backgroundColor = NSColor(JarasTheme.titlebar)
        (window.contentView as? ProjectFrameSizedHosting)?.useProjectWindowFrame()
        guard window.styleMask.contains(.fullSizeContentView) else { return }
        let frame = window.frame
        window.styleMask.remove(.fullSizeContentView)
        window.setFrame(frame, display: false)
    }
    var editor = false
    var login = false
    weak var documents: ProjectDocuments?
    var interfaceScale: CGFloat = 1
    var titlebarColor = NSColor(JarasTheme.titlebar)
    private var applied: NSSize?
    private var applyingGeometry = false
    private weak var configuredWindow: NSWindow?
    private weak var configuredDocuments: ProjectDocuments?
    private var placementObservers: [NSObjectProtocol] = []
    private var minimumObserver: NSKeyValueObservation?
    private var titlebarMonitor: Any?
    private var titlebarRestoreFrame: NSRect?
    private var remembersPlacement = false
    private static let placementKey = "jaras.editorWindowFrame"
    private func rememberPlacement() {
        guard remembersPlacement, let window, !window.inLiveResize,
              !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        let value = NSStringFromRect(window.frame)
        if UserDefaults.standard.string(forKey: Self.placementKey) != value {
            UserDefaults.standard.set(value, forKey: Self.placementKey)
        }
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
        placementObservers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                              NSWindow.didEndLiveResizeNotification, NSWindow.willCloseNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.rememberPlacement() }
        }
        placementObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification,
            object: window, queue: .main) { [weak self, weak window] _ in
            if let window { self?.keepEditorMinimum(on: window) }
        })
    }
    private static func restoredFrame(fallback: NSRect, scale: CGFloat) -> NSRect {
        guard let saved = UserDefaults.standard.string(forKey: placementKey) else { return fallback }
        var frame = NSRectFromString(saved)
        guard frame.width > 0, frame.height > 0, frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite else { return fallback }
        let screen = NSScreen.screens.max { a, b in
            let ar = a.visibleFrame.intersection(frame), br = b.visibleFrame.intersection(frame)
            return (ar.isNull ? 0 : ar.width * ar.height) < (br.isNull ? 0 : br.width * br.height)
        }
        let visible = screen.flatMap { $0.visibleFrame.intersects(frame) ? $0.visibleFrame : nil } ?? NSScreen.main?.visibleFrame ?? fallback
        frame.size.width = min(max(editorMinimumFrameSize.width * scale, frame.width), visible.width)
        frame.size.height = min(max(editorMinimumFrameSize.height * scale, frame.height), visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }
    private func applyMinimum(_ minimum: NSSize, available: NSSize, to window: NSWindow) {
        let size = NSSize(width: min(available.width, minimum.width * interfaceScale),
                          height: min(available.height, minimum.height * interfaceScale))
        if window.minSize != size {
            window.contentMinSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: size)).size
        }
    }
    private func keepEditorMinimum(on window: NSWindow) {
        guard editor, configuredWindow === window else { return }
        applyMinimum(Self.editorMinimumFrameSize, available: window.screen?.visibleFrame.size ?? Self.editorFrameSize, to: window)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); update() }
    func update() {
        guard let window, !applyingGeometry else { return }
        applyingGeometry = true
        defer { applyingGeometry = false }
        if editor { Self.editorWindow = window }
        else if Self.editorWindow === window { Self.editorWindow = nil }
        if let documents, configuredWindow !== window || configuredDocuments !== documents {
            ProjectionWindow.bindWorkspace(window)
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
            // SwiftUI can publish its content minimum after the native frame
            // changes. Restore the editor's outer limit without replacing the
            // window delegate or relaying out the whole workspace.
            minimumObserver = window.observe(\.contentMinSize, options: [.new]) { [weak self, weak window] _, _ in
                DispatchQueue.main.async {
                    guard let self, let window else { return }
                    self.keepEditorMinimum(on: window)
                }
            }
        }
        if window.backgroundColor != titlebarColor { window.backgroundColor = titlebarColor }
        let size = editor ? Self.editorFrameSize : NSSize(width: 600, height: login ? 760 : 460)
        let available = window.screen?.visibleFrame.size ?? size
        let minimum = editor ? Self.editorMinimumFrameSize : NSSize(width: 600, height: 460)
        guard applied != size else {
            applyMinimum(minimum, available: available, to: window)
            return
        }
        rememberPlacement()
        remembersPlacement = false
        applied = size
        if editor || login {
            if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
        } else if window.styleMask.contains(.resizable) {
            window.styleMask.remove(.resizable)
        }
        if !editor { applyMinimum(minimum, available: available, to: window) }
        let frameSize = NSSize(width: min(size.width, available.width), height: min(size.height, available.height))
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let fallback = NSRect(x: visible.midX - frameSize.width / 2, y: visible.midY - frameSize.height / 2,
                              width: frameSize.width, height: frameSize.height)
        let destination = editor ? Self.restoredFrame(fallback: fallback, scale: interfaceScale) : fallback
        if !window.styleMask.contains(.fullScreen), window.frame != destination {
            window.setFrame(destination, display: false, animate: false)
        }
        // Raising the minimum on the compact Home window first makes AppKit
        // resize it to the editor minimum before it reaches its saved frame.
        if editor { applyMinimum(minimum, available: available, to: window) }
        remembersPlacement = editor
        rememberPlacement()
    }
}
#endif

#if os(macOS)
private final class ProjectCopyPanelValidator: NSObject, NSOpenSavePanelDelegate {
    private let sourceFolder: URL
    init(source: URL) { sourceFolder = source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL }
    func panel(_ sender: Any, validate url: URL) throws {
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL != sourceFolder,
              !FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectError.invalid(JarasLocalization.string("Choose another folder and an unused .jl filename."))
        }
    }
}

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
/// A process-wide snapshot lets other project tabs paste the same selection.
/// A new Finder copy replaces the token so stale internal items cannot win Cmd+V.
@MainActor final class GridMediaClipboard {
    static let shared = GridMediaClipboard()
    enum Source: Equatable { case items, tracks, files([URL]), none }
    private let pasteboard: NSPasteboard
    private let itemType = NSPasteboard.PasteboardType("com.catlive.grid-items")
    private var token: String?
    private var tracksCopied = false
    var items: GridItemClipboard?
    var directory: URL?
    var session: UUID?
    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    func didCopyItems() {
        tracksCopied = false
        claimClipboard()
    }
    func didCopyTracks(session: UUID) {
        tracksCopied = true; items = nil; directory = nil; self.session = session
        claimClipboard()
    }
    private func claimClipboard() {
        let value = UUID().uuidString
        pasteboard.clearContents()
        token = pasteboard.setString(value, forType: itemType) ? value : nil
    }
    func source() -> Source {
        if let token, pasteboard.string(forType: itemType) == token { return tracksCopied ? .tracks : .items }
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

/// Lives outside the active document so switching tabs cannot reset progress.
@MainActor final class MultipleProjectOpening: ObservableObject {
    static let shared = MultipleProjectOpening()
    @Published private(set) var total = 0
    @Published private(set) var completed = 0
    @Published private(set) var current: URL?
    @Published var error = ""
    var running: Bool { current != nil }
    func open(_ urls: [URL], perform: @escaping (URL) async throws -> Void) {
        guard !running else { return }
        var seen = Set<String>()
        let queue = urls.filter { seen.insert($0.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
        guard let first = queue.first else { return }
        total = queue.count; completed = 0; current = first; error = ""
        Task { @MainActor in
            defer { current = nil }
            do {
                for url in queue {
                    current = url
                    try await perform(url)
                    completed += 1
                    await Task.yield()
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}
private struct RecentProjectCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? JarasTheme.green : JarasTheme.secondary)
                configuration.label
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
private struct RecentMultipleProjectPicker: View {
    let urls: [URL]
    let cancel: () -> Void
    let open: ([URL]) -> Void
    @State private var selected: [URL] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open multiple projects").font(.jarasHeadline)
            Text("Select projects in the order you want their tabs to appear.")
                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(urls, id: \.path) { url in
                        Toggle(isOn: Binding(get: { selected.contains(url) }, set: { enabled in
                            if enabled { if !selected.contains(url) { selected.append(url) } }
                            else { selected.removeAll { $0 == url } }
                        })) {
                            HStack(spacing: 8) {
                                Text(verbatim: selected.firstIndex(of: url).map { String($0 + 1) } ?? "—")
                                    .monospacedDigit().frame(width: 28)
                                VStack(alignment: .leading) {
                                    Text(verbatim: url.deletingPathExtension().lastPathComponent).lineLimit(1)
                                    Text(verbatim: url.deletingLastPathComponent().path).font(.jarasCaption)
                                        .foregroundStyle(JarasTheme.secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }.toggleStyle(RecentProjectCheckboxStyle()).disabled(RecentProjectEntry.isMissing(url))
                    }
                }.padding(8)
            }
            HStack {
                Button("Cancel", action: cancel)
                Spacer()
                Button("Open") { open(selected) }.disabled(selected.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520, height: 460).background(JarasTheme.background)
    }
}
struct MultipleProjectOpeningOverlay: View {
    @ObservedObject private var opening = MultipleProjectOpening.shared
    var body: some View {
        ZStack {
            if opening.running {
                Color.black.opacity(0.5).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text("Opening projects…").font(.jarasHeadline)
                    ProgressView(value: Double(opening.completed), total: Double(max(1, opening.total)))
                        .progressViewStyle(JarasProgressBarStyle()).tint(JarasTheme.green)
                    HStack {
                        Text(verbatim: opening.current?.deletingPathExtension().lastPathComponent ?? "").lineLimit(1)
                        Spacer()
                        Text(verbatim: "\(min(opening.total, opening.completed + 1))/\(opening.total)").monospacedDigit()
                    }.font(.jarasCaption)
                }.padding(24).frame(width: 400).background(JarasTheme.panel)
                    .foregroundStyle(JarasTheme.text).clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }.alert("Could not open project", isPresented: Binding(get: { !opening.error.isEmpty }, set: { if !$0 { opening.error = "" } })) {
            Button("OK") { opening.error = "" }
        } message: { Text(verbatim: opening.error) }
    }
}
