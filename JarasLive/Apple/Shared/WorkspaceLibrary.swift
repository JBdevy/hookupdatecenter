import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

private struct LibraryScrollView<Content: View>: View {
    let axes: Axis.Set
    @ViewBuilder let content: () -> Content
    @WorkspacePreference(JarasInterfaceTheme.preferenceKey) private var theme = JarasInterfaceTheme.defaultTheme

    init(_ axes: Axis.Set = .vertical, @ViewBuilder content: @escaping () -> Content) {
        self.axes = axes
        self.content = content
    }

    var body: some View {
        ScrollView(axes) {
            content()
                #if os(macOS)
                .background(LibraryScrollerSetup(axes: axes, rail: NSColor(Color(hex: theme.scrollRailHex))))
                #endif
        }
    }
}

#if os(macOS)
private struct LibraryScrollerSetup: NSViewRepresentable {
    let axes: Axis.Set
    let rail: NSColor

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.axes = axes
        view.rail = rail
        view.configure()
    }

    final class Probe: NSView {
        var axes: Axis.Set = .vertical
        var rail = NSColor.clear

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
            DispatchQueue.main.async { [weak self] in self?.configure() }
        }

        override func layout() {
            super.layout()
            configure()
        }

        func configure() {
            guard let scroll = enclosingScrollView else { return }
            if scroll.scrollerStyle != .legacy { scroll.scrollerStyle = .legacy }
            if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
            if axes.contains(.vertical) {
                if !(scroll.verticalScroller is GridNativeScrollView.GreenScroller) {
                    let bar = GridNativeScrollView.GreenScroller(frame: NSRect(x: 0, y: 0, width: 11, height: 100))
                    bar.controlSize = .small
                    scroll.verticalScroller = bar
                }
                (scroll.verticalScroller as? GridNativeScrollView.GreenScroller)?.slotColor = rail
            }
            if axes.contains(.horizontal) {
                if !(scroll.horizontalScroller is GridNativeScrollView.GreenScroller) {
                    let bar = GridNativeScrollView.GreenScroller(frame: NSRect(x: 0, y: 0, width: 100, height: 11))
                    bar.controlSize = .small
                    scroll.horizontalScroller = bar
                }
                (scroll.horizontalScroller as? GridNativeScrollView.GreenScroller)?.slotColor = rail
            }
        }
    }
}
#endif

private struct LibraryPreviewGainKnob: View {
    @Binding var value: Double
    @State private var origin: Double?

    var body: some View {
        Canvas { context, size in
            context.withCGContext {
                MixerPanFace.draw(value: 1 + value / 30, in: CGRect(origin: .zero, size: size), context: $0)
            }
        }
        .frame(width: 24, height: 28)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { drag in
                if origin == nil { origin = value }
                setGain((origin ?? value) + Double(drag.translation.width - drag.translation.height) * 0.5)
            }
            .onEnded { _ in origin = nil })
        .onTapGesture(count: 2) { setGain(0) }
        .accessibilityLabel("Sample preview volume")
        .accessibilityValue(value <= -60 ? "−∞ dB" : String(format: "%.0f dB", value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setGain(value + 1)
            case .decrement: setGain(value - 1)
            @unknown default: break
            }
        }
    }

    private func setGain(_ next: Double) { value = min(0, max(-60, next.rounded())) }
}

private struct LibraryRowDrag: ViewModifier {
    let title: String
    let type: UTType
    let data: () -> Data?
    let provider: () -> NSItemProvider
    var click: (() -> Void)?

    func body(content: Content) -> some View {
        #if os(macOS)
        content.overlay(LibraryRowDragInput(title: title, type: type, data: data, click: click))
        #else
        content.onDrag(provider)
        #endif
    }
}

#if os(macOS)
private struct LibraryRowDragInput: NSViewRepresentable {
    let title: String
    let type: UTType
    let data: () -> Data?
    let click: (() -> Void)?

    func makeNSView(context: Context) -> LibraryRowDragView { LibraryRowDragView() }
    func updateNSView(_ view: LibraryRowDragView, context: Context) {
        view.title = title; view.type = NSPasteboard.PasteboardType(type.identifier)
        view.data = data; view.click = click
    }
}

private final class LibraryRowDragView: NSView, NSDraggingSource {
    var title = ""
    var type = NSPasteboard.PasteboardType("")
    var data: (() -> Data?)?
    var click: (() -> Void)?
    private var pressedAt: NSPoint?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressedAt = event.locationInWindow }
    override func mouseUp(with event: NSEvent) {
        defer { pressedAt = nil }
        if pressedAt != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { click?() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let pressedAt, hypot(event.locationInWindow.x - pressedAt.x, event.locationInWindow.y - pressedAt.y) >= 4,
              let bytes = data?() else { return }
        self.pressedAt = nil
        let pasteboard = NSPasteboardItem()
        pasteboard.setData(bytes, forType: type)
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        let title = self.title
        let rect = CGRect(x: 0, y: 0, width: max(1, bounds.width), height: max(1, bounds.height))
        let badge = NSImage(size: rect.size, flipped: false) { image in
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: image, xRadius: 5, yRadius: 5).fill()
            (title as NSString).draw(in: image.insetBy(dx: 7, dy: 4), withAttributes: [
                .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12, weight: .medium)])
            return true
        }
        item.setDraggingFrame(rect, contents: badge)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
#endif

private actor LibrarySoundFontPreviewRenderer {
    static let shared = LibrarySoundFontPreviewRenderer()

    func render(_ url: URL, drums: Bool) throws -> AVAudioPCMBuffer {
        // Banks can be hundreds of MB. Serialize loads and skip queued work
        // when a new preview replaces it.
        try Task.checkCancellation()
        return try JarasSoundFont.libraryPreview(at: url, drums: drums)
    }
}

#if os(iOS)
enum WorkspaceBrowserFileTransfer {
    static let type = UTType(exportedAs: "com.catlive.workspace-file", conformingTo: .data)
    private struct Payload: Codable {
        let file: URL
        let bookmark: Data?
    }

    static func provider(_ file: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = file.lastPathComponent
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            let bookmark = scoped ? try? file.bookmarkData() : nil
            do {
                completion(try JSONEncoder().encode(Payload(file: file, bookmark: bookmark)), nil)
            } catch { completion(nil, error) }
            return nil
        }
        return provider
    }

    static func load(_ provider: NSItemProvider, completion: @escaping (Result<URL, Error>) -> Void) {
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
            completion(Result {
                guard let data else {
                    throw error ?? ProjectError.invalid("Could not read the dropped file.")
                }
                let payload = try JSONDecoder().decode(Payload.self, from: data)
                var stale = false
                let resolved = payload.bookmark.flatMap {
                    try? URL(resolvingBookmarkData: $0, bookmarkDataIsStale: &stale)
                } ?? payload.file
                guard resolved.isFileURL else { throw ProjectError.invalid("Could not read the dropped file.") }
                return resolved
            })
        }
    }
}
#endif

@MainActor private final class WorkspaceFiles: ObservableObject {
    struct Entry: Identifiable, Sendable {
        let url: URL
        let name: String
        let folder: Bool
        var volume = false
        var id: URL { url }
    }
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var path: [URL] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var grantedFolders: [URL: Bool] = [:]
    #if os(iOS)
    private static let folderBookmarksKey = "catlive.files.folderBookmarks"
    private var restoredFolders = false
    #endif
    private var past: [[URL]] = []
    private var future: [[URL]] = []
    private var folders: [[URL]: [Entry]] = [:]
    private var request: UUID?
    private var task: Task<Void, Never>?

    var canGoBack: Bool { !past.isEmpty }
    var canGoForward: Bool { !future.isEmpty }

    deinit {
        task?.cancel()
        for (url, granted) in grantedFolders where granted { url.stopAccessingSecurityScopedResource() }
    }

    func openFolder(_ url: URL, from depth: Int) {
        navigate(to: Array(path.prefix(depth)) + [url])
    }

    func navigate(to target: [URL]) {
        guard target != path else { return }
        past.append(path)
        if past.count > 64 { past.removeFirst() }
        future.removeAll()
        path = target
        refresh()
    }

    func back() {
        guard let previous = past.popLast() else { return }
        future.append(path)
        path = previous
        refresh()
    }

    func forward() {
        guard let next = future.popLast() else { return }
        past.append(path)
        path = next
        refresh()
    }

    func addFolder(_ url: URL) {
        if grantedFolders[url] == nil { grantedFolders[url] = url.startAccessingSecurityScopedResource() }
        #if os(iOS)
        if let bookmark = try? url.bookmarkData() {
            let defaults = UserDefaults.standard
            var saved = defaults.array(forKey: Self.folderBookmarksKey) as? [Data] ?? []
            saved.removeAll { Self.resolveBookmark($0)?.standardizedFileURL == url.standardizedFileURL }
            saved.append(bookmark)
            defaults.set(saved, forKey: Self.folderBookmarksKey)
        }
        #endif
        folders.removeValue(forKey: [])
        if path == [url] { refresh() }
        else { navigate(to: [url]) }
    }

    func contents(at depth: Int) -> [Entry] {
        depth == path.count ? entries : folders[Array(path.prefix(depth))] ?? []
    }

    func title(for url: URL, at depth: Int) -> String {
        contents(at: depth).first { $0.url == url }?.name ?? (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
    }

    func mountsChanged() {
        folders.removeAll()
        refresh()
    }

    #if os(iOS)
    func createFolder(named name: String, in parent: URL) async throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw ProjectError.invalid(JarasLocalization.string("Invalid folder name"))
        }
        try await Task.detached(priority: .userInitiated) {
            var coordinationError: NSError?
            var result: Result<Void, Error>?
            NSFileCoordinator().coordinate(writingItemAt: parent, options: [], error: &coordinationError) { directory in
                result = Result {
                    try FileManager.default.createDirectory(at: directory.appendingPathComponent(name, isDirectory: true),
                                                            withIntermediateDirectories: false)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw ProjectError.invalid("Could not access the selected folder.") }
            try result.get()
        }.value
        folders = folders.filter { $0.key.last != parent }
        if path.last == parent { refresh() }
    }

    private static func resolveBookmark(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
    }

    private func restoreFolders() {
        guard !restoredFolders else { return }
        restoredFolders = true
        let saved = UserDefaults.standard.array(forKey: Self.folderBookmarksKey) as? [Data] ?? []
        for bookmark in ProjectDocuments.nativeFileBrowserBookmarks + saved {
            guard let url = Self.resolveBookmark(bookmark), grantedFolders[url] == nil else { continue }
            if url.startAccessingSecurityScopedResource() { grantedFolders[url] = true }
        }
    }
    #endif

    func refresh() {
        #if os(iOS)
        restoreFolders()
        #endif
        task?.cancel()
        let id = UUID(), currentPath = path, granted = Array(grantedFolders.keys)
        let missing = (0..<currentPath.count).map { Array(currentPath.prefix($0)) }.filter { folders[$0] == nil }
        request = id
        entries = folders[currentPath] ?? []
        loading = entries.isEmpty
        error = nil
        task = Task {
            let (parents, result) = await Task.detached(priority: .userInitiated) {
                let parents = missing.compactMap { ancestor -> ([URL], [Entry])? in
                    guard let contents = try? Self.list(ancestor.last, granted: granted) else { return nil }
                    return (ancestor, contents)
                }
                return (parents, Result { try Self.list(currentPath.last, granted: granted) })
            }.value
            guard !Task.isCancelled, request == id else { return }
            for (ancestor, contents) in parents { folders[ancestor] = contents }
            if folders.count > 128 {
                let retained = Set((0..<currentPath.count).map { Array(currentPath.prefix($0)) })
                folders = folders.filter { retained.contains($0.key) }
            }
            loading = false
            switch result {
            case .success(let contents):
                folders[currentPath] = contents
                entries = contents
            case .failure(let failure):
                entries = []
                error = failure.localizedDescription
            }
        }
    }

    private nonisolated static func list(_ folder: URL?, granted: [URL]) throws -> [Entry] {
        let manager = FileManager.default
        if let folder {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .nameKey, .isPackageKey, .contentTypeKey]
            let entries = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                           options: [.skipsHiddenFiles])
            return entries.compactMap { url -> Entry? in
                guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                let folder = values.isDirectory == true && values.isPackage != true
                guard folder || supports(url, type: values.contentType) else { return nil }
                return Entry(url: url, name: values.name ?? url.lastPathComponent,
                             folder: folder)
            }.sorted { a, b in
                if a.folder != b.folder { return a.folder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        #if os(macOS)
        let shortcuts = [manager.homeDirectoryForCurrentUser] + [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory]
            .compactMap { manager.urls(for: $0, in: .userDomainMask).first }
        let volumes = (manager.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? [])
            .map { url in
                let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
                return Entry(url: url, name: name ?? url.path, folder: true, volume: true)
            }
        let saved = (shortcuts + granted).map { Entry(url: $0, name: manager.displayName(atPath: $0.path), folder: true) }
        var seen = Set<URL>()
        return (volumes + saved).filter { seen.insert($0.url).inserted }
        #else
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first
        let picked = granted.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var seen = Set<URL>()
        return ([documents].compactMap { $0 } + picked)
            .filter { seen.insert($0.standardizedFileURL).inserted }
            .map { Entry(url: $0, name: manager.displayName(atPath: $0.path), folder: true) }
        #endif
    }
    private nonisolated static func supports(_ url: URL, type contentType: UTType?) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["jl", "bkjl", "ziplive", "jllyrics", "mid", "midi", "sf2", "wav", "wave", "aif", "aiff",
            "mp3", "m4a", "aac", "caf", "flac"].contains(ext) { return true }
        #if os(macOS)
        if ["rpp", "logicx"].contains(ext) { return true }
        #endif
        guard let type = contentType ?? UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .image)
    }
}

private struct WorkspaceFilesPane: View {
    @ObservedObject var files: WorkspaceFiles
    let theme: JarasInterfaceTheme
    @WorkspacePreference("catlive.files.columns") private var columns = true
    @State private var query = ""
    @State private var choosingFolder = false
    @State private var selectionError: String?
    #if os(iOS)
    @State private var creatingFolder = false
    @State private var folderName = ""
    @State private var folderError: String?
    #endif

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            breadcrumb
            search
            Divider()
            #if os(iOS)
            if files.path.isEmpty {
                Button { choosingFolder = true } label: {
                    Label("Browse in Files", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                        .foregroundStyle(JarasTheme.green)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider()
            }
            #endif
            if columns { columnBrowser }
            else { fileList(depth: files.path.count) }
        }
        .font(.jarasSystem(size: 11))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { files.refresh() }
        .onChange(of: files.path) { _ in query = ""; selectionError = nil }
        #if os(iOS)
        .sheet(isPresented: $choosingFolder) {
            WorkspaceFilesFolderPicker(directory: files.path.last) { folder in
                if let folder { selectionError = nil; files.addFolder(folder) }
                choosingFolder = false
            }
        }
        .alert("Create folder", isPresented: $creatingFolder) {
            TextField("Folder name", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                guard let parent = files.path.last else { return }
                let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    do { try await files.createFolder(named: name, in: parent) }
                    catch { folderError = error.localizedDescription }
                }
            }.disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Create folder", isPresented: Binding(get: { folderError != nil }, set: { if !$0 { folderError = nil } })) {
            Button("OK") { folderError = nil }
        } message: { Text(verbatim: folderError ?? "") }
        #else
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): selectionError = nil; files.addFolder(url)
            case .failure(let error): selectionError = error.localizedDescription
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in files.mountsChanged() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in files.mountsChanged() }
        #endif
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 1) {
                button("chevron.left", "Back", action: files.back).disabled(!files.canGoBack)
                button("chevron.right", "Forward", action: files.forward).disabled(!files.canGoForward)
            }.background(theme.panel, in: RoundedRectangle(cornerRadius: 5))
            button("externaldrive", "Locations") { files.navigate(to: []) }
            #if os(macOS)
            button("house", "Home folder") { files.navigate(to: [FileManager.default.homeDirectoryForCurrentUser]) }
            #endif
            button("doc", "Documents folder") {
                if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    files.navigate(to: [documents])
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 1) {
                button("setlist", "List view", active: !columns) { columns = false }
                button("rectangle.split.2x1", "Column view", active: columns) { columns = true }
            }.background(theme.panel, in: RoundedRectangle(cornerRadius: 5))
        }.padding(.horizontal, 7).frame(height: 33)
    }

    private var breadcrumb: some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    Button { files.navigate(to: []) } label: {
                        Label { Text("Locations") } icon: { TransportControlIcon(name: "externaldrive", size: 12) }
                    }.buttonStyle(.plain)
                    ForEach(Array(files.path.enumerated()), id: \.offset) { depth, url in
                        TransportControlIcon(name: "chevron.right", size: 10, color: theme.secondary)
                        Button {
                            files.navigate(to: Array(files.path.prefix(depth + 1)))
                        } label: {
                            Text(verbatim: files.title(for: url, at: depth)).fontWeight(depth == files.path.count - 1 ? .semibold : .regular)
                        }.buttonStyle(.plain)
                    }
                    Color.clear.frame(width: 1).id("path-end")
                }.padding(.horizontal, 7).frame(height: 24)
            }.onChange(of: files.path) { _ in scroll.scrollTo("path-end", anchor: .trailing) }
        }
        .background(theme.panel, in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 7)
    }

    private var search: some View {
        HStack(spacing: 4) {
            HStack(spacing: 5) {
                TransportControlIcon(name: "search", size: 13, color: theme.secondary)
                TextField("Search files", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { TransportControlIcon(name: "xmark.circle.fill", size: 14) }
                        .buttonStyle(.plain).accessibilityLabel(Text("Clear search"))
                }
            }.padding(.horizontal, 7).frame(height: 25)
                .background(theme.display, in: RoundedRectangle(cornerRadius: 5))
            button("refresh", "Refresh folders", action: files.refresh)
            #if os(iOS)
            button("externaldrive", "Browse in Files") { choosingFolder = true }
            button("folder.badge.plus", "Create folder") {
                folderName = ""
                creatingFolder = true
            }.disabled(files.path.isEmpty)
            #else
            button("folder.badge.plus", "Choose folder") { choosingFolder = true }
            #endif
        }.padding(.horizontal, 7).padding(.vertical, 5)
    }

    private func button(_ symbol: String, _ label: LocalizedStringKey,
                        active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TransportControlIcon(name: symbol, size: 14)
                .frame(width: 24, height: 24)
                .foregroundStyle(active ? Color.black : Color.primary)
                .background(active ? JarasTheme.green : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(Text(label))
            .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var columnBrowser: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                LibraryScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        if files.path.isEmpty {
                            fileList(depth: 0).frame(width: geometry.size.width)
                        } else {
                            let width = max(115, geometry.size.width / 2)
                            ForEach(0...files.path.count, id: \.self) { depth in
                                if depth > 0 { Divider() }
                                fileList(depth: depth).frame(width: width).id(depth)
                            }
                        }
                    }.frame(height: geometry.size.height)
                }.onChange(of: files.path) { _ in scroll.scrollTo(files.path.count, anchor: .trailing) }
                    .onAppear { scroll.scrollTo(files.path.count, anchor: .trailing) }
            }
        }
    }

    private func visibleEntries(depth: Int) -> [WorkspaceFiles.Entry] {
        let entries = files.contents(at: depth)
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return depth != files.path.count || term.isEmpty ? entries : entries.filter { $0.name.localizedStandardContains(term) }
    }

    @ViewBuilder private func fileList(depth: Int) -> some View {
        let current = depth == files.path.count
        let entries = visibleEntries(depth: depth)
        if current && files.loading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if current, let error = selectionError ?? files.error {
            Text(verbatim: error).foregroundStyle(theme.secondary).padding(10).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            Text(LocalizedStringKey(query.isEmpty || !current ? "Empty folder" : "No matching files"))
                .foregroundStyle(theme.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LibraryScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        let selected = files.path.indices.contains(depth) && files.path[depth] == entry.url
                        fileRow(entry, depth: depth)
                            .padding(.horizontal, 6).frame(height: 25)
                            .background(selected ? JarasTheme.green.opacity(0.24) : index.isMultiple(of: 2) ? theme.panel.opacity(0.6) : .clear,
                                        in: RoundedRectangle(cornerRadius: 4))
                    }
                }.padding(4)
            }
        }
    }

    @ViewBuilder private func fileRow(_ entry: WorkspaceFiles.Entry, depth: Int) -> some View {
        let label = HStack(spacing: 6) {
            TransportControlIcon(name: entry.volume ? "externaldrive" : entry.folder ? "library.file-folder" : "doc",
                                 size: 14, color: entry.folder ? JarasTheme.green : theme.secondary)
            Text(verbatim: entry.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if entry.folder { TransportControlIcon(name: "chevron.right", size: 10, color: theme.secondary) }
        }.frame(maxWidth: .infinity, minHeight: 24).contentShape(Rectangle())
        if entry.folder {
            Button { files.openFolder(entry.url, from: depth) } label: { label }.buttonStyle(.plain)
        } else {
            #if os(iOS)
            label.onDrag { WorkspaceBrowserFileTransfer.provider(entry.url) }
            #else
            label.onDrag { NSItemProvider(item: entry.url as NSURL, typeIdentifier: UTType.fileURL.identifier) }
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                }
            #endif
        }
    }
}

#if os(iOS)
private struct WorkspaceFilesFolderPicker: UIViewControllerRepresentable {
    let directory: URL?
    let finished: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.directoryURL = directory
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finished: (URL?) -> Void
        init(finished: @escaping (URL?) -> Void) { self.finished = finished }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finished(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finished(nil)
        }
    }
}
#endif

#if os(macOS)
struct DesktopLibraryDock: View {
    let theme: JarasInterfaceTheme
    let show: ShowController
    let available: CGFloat
    @WorkspacePreference("jaras.layout.library.open", store: WorkspaceLayoutPreferences.storage) private var visible = false

    var body: some View {
        DesktopLibraryPane(theme: theme, show: show, available: available, visible: visible)
    }
}

/// Keep live widths inside this sidebar. Publishing them through MainView
/// replaces the grid and Setlist hosting roots on every pointer movement.
struct DesktopLibraryPane: View {
    private struct Layout: Hashable {
        let controller: ObjectIdentifier
        let theme: JarasInterfaceTheme
        let width: CGFloat
        let maximum: CGFloat
    }
    let theme: JarasInterfaceTheme
    let show: ShowController
    let available: CGFloat
    let visible: Bool
    @WorkspacePreference("jaras.layout.library.width", store: WorkspaceLayoutPreferences.storage) private var saved = 344.0
    @WorkspacePreference(WorkspaceLibrary.folderWidthKey, store: WorkspaceLayoutPreferences.storage) private var folders = WorkspaceLibrary.defaultFolderWidth
    @State private var liveWidth: Double?
    @State private var visibilityChanges = PassthroughSubject<Bool, Never>()
    var body: some View {
        let maximum = WorkspaceLibrary.maximumWidth(folders: folders, available: available)
        let width = min(maximum, max(WorkspaceLibrary.minimumPanelWidth, liveWidth ?? saved))
        let layout = Layout(controller: ObjectIdentifier(show), theme: theme, width: width, maximum: maximum)
        RetainedWorkspacePane(width: width, visible: visible, identity: AnyHashable(layout)) {
            ResizableWorkspaceLibrary(theme: theme, show: show, width: width, maximumWidth: maximum,
                preferredWidth: Binding(get: { liveWidth ?? saved }, set: { if $0 != liveWidth { liveWidth = $0 } }),
                finishOuterResize: {
                    if let liveWidth, liveWidth != saved { saved = liveWidth }
                    liveWidth = nil
                }, visibilityChanges: visibilityChanges)
        }
        .frame(width: visible ? width : 0)
        .accessibilityHidden(!visible)
        .onChange(of: visible) { visibilityChanges.send($0) }
    }
}
struct WorkspaceDockContentIdentity: Hashable {
    let project: UUID
    let controller: ObjectIdentifier
    let theme: JarasInterfaceTheme
}

struct DesktopSamplerPane: View {
    let theme: JarasInterfaceTheme
    let show: ShowController
    let visible: Bool
    @State private var visibilityChanges = PassthroughSubject<Bool, Never>()
    var body: some View {
        GeometryReader { geometry in
            RetainedWorkspacePane(width: geometry.size.width, visible: visible,
                identity: AnyHashable(WorkspaceDockContentIdentity(project: show.snapshot.project.id,
                    controller: ObjectIdentifier(show), theme: theme))) {
                WorkspaceLibrary(theme: theme, show: show, samplersOnly: true, visibilityChanges: visibilityChanges)
            }
        }.allowsHitTesting(visible).accessibilityHidden(!visible)
            .onChange(of: visible) { visibilityChanges.send($0) }
    }
}

#endif

private func clampedFolderWidth(_ requested: CGFloat, panel: CGFloat) -> CGFloat {
    let available = max(0, panel - 1)
    let minimum = min(90, max(0, available - WorkspaceLibrary.minimumDetailsWidth))
    let maximum = max(minimum, available - WorkspaceLibrary.minimumDetailsWidth)
    return min(maximum, max(minimum, requested))
}

private func libraryResizeEdge(theme: JarasInterfaceTheme, label: LocalizedStringKey, value: CGFloat,
                               maximum: CGFloat, affectsTimeline: Bool = false, start: Binding<CGFloat?>,
                               ended: @escaping () -> Void, moved: @escaping (CGFloat) -> Void) -> some View {
    ZStack {
        Rectangle().fill(theme.line.opacity(0.7)).frame(width: 1)
        #if os(macOS)
        MixerResizeHandle(width: value, maximum: maximum, showsScrollRail: false, showsRail: false,
                          maximumResizeFrequency: 60, retainsTimelineCoverage: affectsTimeline,
                          onCancel: ended, onEnd: { moved($0); ended() }, onResize: moved)
        #else
        Color.clear.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { drag in
                    if start.wrappedValue == nil { start.wrappedValue = value }
                    moved((start.wrappedValue ?? value) + drag.translation.width)
                }
                .onEnded { drag in
                    if let origin = start.wrappedValue { moved(origin + drag.translation.width) }
                    start.wrappedValue = nil
                    ended()
                })
        #endif
    }
    .frame(width: 7)
    .accessibilityLabel(Text(label))
    .accessibilityAdjustableAction { direction in
        moved(value + (direction == .increment ? 16 : -16))
        ended()
    }
}

struct ResizableWorkspaceLibrary: View {
    let theme: JarasInterfaceTheme
    let show: ShowController
    let width: CGFloat
    let maximumWidth: CGFloat
    @Binding var preferredWidth: Double
    var finishOuterResize: (() -> Void)? = nil
    var visibilityChanges: PassthroughSubject<Bool, Never>? = nil

    @WorkspacePreference(WorkspaceLibrary.folderWidthKey, store: WorkspaceLayoutPreferences.storage)
    private var folderWidth = WorkspaceLibrary.defaultFolderWidth
    @State private var dragStart: CGFloat?

    private struct Catalog: View, Equatable {
        let theme: JarasInterfaceTheme
        let show: ShowController
        let visibilityChanges: PassthroughSubject<Bool, Never>?
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.theme == rhs.theme && lhs.show === rhs.show && lhs.visibilityChanges === rhs.visibilityChanges
        }
        var body: some View {
            WorkspaceLibrary(theme: theme, show: show, visibilityChanges: visibilityChanges)
        }
    }

    var body: some View {
        Catalog(theme: theme, show: show, visibilityChanges: visibilityChanges).equatable()
            .overlay(alignment: .trailing) {
                libraryResizeEdge(theme: theme, label: "Resize Library", value: width, maximum: maximumWidth,
                                  affectsTimeline: true, start: $dragStart,
                                  ended: { finishOuterResize?() }) {
                    let minimum = min(maximumWidth,
                        max(90, clampedFolderWidth(folderWidth, panel: width)) + 1 + WorkspaceLibrary.minimumDetailsWidth)
                    let next = min(maximumWidth, max(minimum, $0))
                    if next != preferredWidth { preferredWidth = next }
                }
            }
    }
}

private struct LibraryColumns<Folders: View, Entries: View>: View {
    let theme: JarasInterfaceTheme
    let folders: Folders
    let entries: Entries
    @WorkspacePreference(WorkspaceLibrary.folderWidthKey, store: WorkspaceLayoutPreferences.storage)
    private var folderWidth = WorkspaceLibrary.defaultFolderWidth
    @State private var liveFolderWidth: CGFloat?
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let panel = geometry.size.width
            let column = clampedFolderWidth(liveFolderWidth ?? folderWidth, panel: panel)
            HStack(spacing: 0) {
                folders.frame(width: column)
                Rectangle().fill(theme.line.opacity(0.65)).frame(width: 1)
                entries.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(theme.libraryEntriesBackground)
                    .clipped()
            }
            .overlay(alignment: .leading) {
                libraryResizeEdge(theme: theme, label: "Resize Library folders", value: column,
                                  maximum: panel, start: $dragStart, ended: {
                    if let liveFolderWidth, liveFolderWidth != folderWidth { folderWidth = liveFolderWidth }
                    liveFolderWidth = nil
                }) {
                    let next = clampedFolderWidth($0, panel: panel)
                    if next != liveFolderWidth { liveFolderWidth = next }
                }.offset(x: column - 3)
            }
        }
    }
}

private struct LibraryNote: Codable, Identifiable {
    static let storageKey = "jaras.library.annotations"
    var id = UUID()
    var text = ""
    var name: String?

    var title: String {
        name.flatMap { $0.isEmpty ? nil : $0 } ?? JarasLocalization.string("Untitled note")
    }

    static func decode(_ data: Data) -> [Self] {
        (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }

    @MainActor
    static func saveText(_ text: String, for id: UUID) {
        let storage = WorkspaceLayoutPreferences.storage
        var notes = decode(storage.data(forKey: storageKey) ?? Data())
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        if let updated = try? JSONEncoder().encode(notes) {
            storage.set(updated, forKey: storageKey)
        }
    }

    static func saving(_ note: Self, name: String, in notes: [Self]) -> [Self] {
        var updated = notes
        if let index = updated.firstIndex(where: { $0.id == note.id }) {
            updated[index].name = name
        } else {
            var created = note
            created.name = name
            updated.append(created)
        }
        return updated
    }
}

private struct LibraryNoteNameInput: View {
    let note: LibraryNote
    let saved: (String) -> Void
    @State private var name: String
    @FocusState private var focused: Bool

    init(note: LibraryNote, saved: @escaping (String) -> Void) {
        self.note = note
        self.saved = saved
        _name = State(initialValue: note.name ?? "")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note.name == nil ? "Note name" : "Rename note").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit(save)
            Button(note.name == nil ? "Create" : "Save", action: save).disabled(trimmedName.isEmpty)
        }
        .padding(12).frame(width: 240)
        .onAppear { focused = true }
    }

    private func save() {
        if !trimmedName.isEmpty { saved(trimmedName) }
    }
}

private struct LibraryNoteEditor: View {
    let note: LibraryNote
    let confirm: () -> Void

    var body: some View {
        Group {
            #if os(macOS)
            TextItemNotepad(text: .constant(note.text), apply: confirm, cancel: {},
                            saveNote: { LibraryNote.saveText($0, for: note.id) })
            #else
            let text = Binding(get: { note.text }, set: { LibraryNote.saveText($0, for: note.id) })
            NativeFullLyricsInput(text: text, outlineStanzas: false,
                                  font: UIFont(name: CatLiveTypeface.name(nil), size: 15) ?? .systemFont(ofSize: 15),
                                  startsEditingOnAppear: true)
            #endif
        }.accessibilityLabel("Notes").padding(5)
    }
}

private struct LibraryNoteReadingView: View {
    let text: String

    private var styledText: AttributedString {
        var result = AttributedString()
        for run in ItemTextColors.runs(text) {
            var value = AttributedString(run.text)
            value.foregroundColor = run.color.map { Color(hex: $0) } ?? JarasTheme.text
            result += value
        }
        return result
    }

    var body: some View {
        LibraryScrollView {
            Text(styledText)
                .font(.jarasSystem(size: 14))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(JarasTheme.background)
        .padding(5)
    }
}

private struct EditableLibraryNote<Header: View>: View {
    let note: LibraryNote
    @ViewBuilder let header: () -> Header
    @State private var editing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                header().frame(maxWidth: .infinity, alignment: .leading)
                Button { editing.toggle() } label: {
                    Image(systemName: editing ? "checkmark" : "pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 24)
                        .foregroundStyle(editing ? Color.black : JarasTheme.text)
                        .background(editing ? JarasTheme.green : Color(hex: 0x454545),
                                    in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(editing ? Text("Confirm note edit") : Text("Edit note"))
                .accessibilityIdentifier("notes-edit-toggle")
            }.padding(5)
            if editing {
                LibraryNoteEditor(note: note) { editing = false }
            } else {
                LibraryNoteReadingView(text: note.text)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct LibraryDockPickerButton: View {
    let title: String
    let current: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                TransportControlIcon(name: "setlist", size: 17)
                    .frame(width: 28, height: 24)
                    .background(Color(hex: 0x454545), in: RoundedRectangle(cornerRadius: 5))
                Text(verbatim: current).font(.jarasSystem(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(Text(LocalizedStringKey(title))).accessibilityValue(current)
    }
}

private struct LibraryDockPickerRow: View {
    let title: String
    var selected = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 19)
                    .accessibilityHidden(true)
                Text(verbatim: title).font(.jarasSystem(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 7)
            .padding(.trailing, 20)
            .frame(height: 24)
            .background {
                if hovered {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(hex: 0x48484b))
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct LibraryDockPickerList<Content: View>: View {
    let rowCount: Int
    let hasSeparator: Bool
    @ViewBuilder let content: () -> Content

    static var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.13))
            .frame(height: 1)
            .padding(.horizontal, 9)
            .frame(height: 9)
    }

    var body: some View {
        LibraryScrollView {
            VStack(alignment: .leading, spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 178, height: min(300, CGFloat(rowCount * 24 + (hasSeparator ? 9 : 0))))
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Color(hex: 0x2b2b2d), Color(hex: 0x262628)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(0.17), lineWidth: 1)
                }
        }
        .foregroundStyle(Color(hex: 0xf2f2f2))
    }
}

@MainActor struct WorkspaceNotesDock: View {
    enum Tab: String, CaseIterable {
        case notes = "Notes"
        case region = "Region"
        case markers = "Markers"
    }
    let theme: JarasInterfaceTheme
    let show: ShowController
    @Binding var tab: Tab
    let closeSetlist: () -> Void
    @WorkspacePreference(LibraryNote.storageKey, store: WorkspaceLayoutPreferences.storage) private var storedNotes = Data()
    @State private var selection: UUID?
    @State private var namingNote: LibraryNote?
    @State private var showingPicker = false

    private var notes: [LibraryNote] { LibraryNote.decode(storedNotes) }
    private var activeNote: LibraryNote? { notes.first { $0.id == selection } ?? notes.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button {
                        if item != .notes {
                            closeSetlist()
                            show.libraryTimelineSelection.openedPane.send(.dock)
                        }
                        tab = item
                        showingPicker = false
                    } label: {
                        Text(verbatim: item.rawValue)
                            .font(.jarasSystem(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity).frame(height: 25)
                            .foregroundStyle(tab == item ? Color.black : JarasTheme.text)
                            .background(tab == item ? JarasTheme.green : Color.white.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }.padding(5)
            if tab == .notes {
                notesPanel
            } else {
                LibraryTimelineList(show: show, regions: tab == .region, docked: true)
                    .id(tab)
            }
        }.frame(maxHeight: .infinity, alignment: .top)
            .background(theme.mixerPanelBackground).foregroundStyle(JarasTheme.text)
            .onReceive(show.libraryTimelineSelection.openedPane) { pane in
                if pane == .library { tab = .notes }
            }
    }

    @ViewBuilder private var notesPanel: some View {
        if let note = activeNote {
            EditableLibraryNote(note: note) { notePicker }
                .id(note.id)
        } else {
            notePicker.padding(5).frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var notePicker: some View {
        LibraryDockPickerButton(title: "Notes", current: activeNote?.title ?? JarasLocalization.string("Notes")) {
            namingNote = nil
            showingPicker.toggle()
        }
        .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
            if let namingNote {
                LibraryNoteNameInput(note: namingNote) { name in
                    persist(LibraryNote.saving(namingNote, name: name, in: notes))
                    selection = namingNote.id
                    showingPicker = false
                }
            } else {
                LibraryDockPickerList(rowCount: notes.count + (activeNote == nil ? 1 : 2), hasSeparator: !notes.isEmpty) {
                    LibraryDockPickerRow(title: JarasLocalization.string("Create")) { namingNote = LibraryNote() }
                    if let activeNote {
                        LibraryDockPickerRow(title: JarasLocalization.string("Rename note")) { namingNote = activeNote }
                        LibraryDockPickerList<EmptyView>.separator
                    }
                    ForEach(notes) { note in
                        LibraryDockPickerRow(title: note.title, selected: activeNote?.id == note.id) {
                            selection = note.id
                            showingPicker = false
                        }
                    }
                }
            }
        }
    }

    private func persist(_ notes: [LibraryNote]) {
        if let encoded = try? JSONEncoder().encode(notes) { storedNotes = encoded }
    }
}
struct WorkspaceLibrary: View {
    static let folderWidthKey = "jaras.library.foldersWidth"
    static let defaultFolderWidth = 146.0
    static let minimumDetailsWidth: CGFloat = 140
    static let minimumPanelWidth: CGFloat = 90 + 1 + minimumDetailsWidth
    @MainActor private static var categoriesImporting = Set<UUID>()
    private static let maximumDetailsWidth: CGFloat = 364.4921875
    static func maximumWidth(folders: Double, available: CGFloat) -> CGFloat {
        min(available, max(90, CGFloat(folders)) + 1 + maximumDetailsWidth)
    }
    private enum Selection: Hashable {
        case instrument(InstrumentCategory)
        case plugins(String?)
        case samplerCategory(UUID)
        case padSamplers
        case nativeSamplers(String)
        case midiChords(String)
        case midiCategory(UUID)
        case preset(String)
        case favoritePlugins, favoriteSamplers
        case annotation(UUID)
        case regions, markers
    }


    private struct SamplerCategory: Codable, Identifiable {
        var id = UUID()
        let name: String
    }

    private struct Sampler: Identifiable, Sendable {
        let url: URL
        var id: URL { url }
        var favoriteKey: String { url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    private static let nativeSampleRoot = Bundle.main.resourceURL?.appendingPathComponent("NativeSamples", isDirectory: true)
    private static let voiceGuideCategories = ["Guia Pack PT-BR 1", "Guia Pack PT-BR 2", "Guia Pack ENG 1", "Guia Pack ENG 2"]
    private static let otherNativeSampleCategories = ["Cymbals", "FX", "FX Brazil", "Kick", "Percussion", "Snare", "Toms"]
    private static let nativeSampleCategories = voiceGuideCategories + otherNativeSampleCategories

    private static let nativeTypes: [String: String] = [
        NativeFXSettings.waveLFOName: "Dynamics", "EQ": "EQ", "Compressor": "Dynamics", "Pitch": "Pitch Shift", "Delay": "Delay",
        "Reverb": "Reverb", NativeFXSettings.reverbConvolution: "Reverb", "Limiter": "Dynamics", "CatLive Trigger": "Trigger", "Cat Gate": "Dynamics",
        "Chorus": "Modulation", "Phaser": "Modulation", "Amp": "Distortion", "Soft Clipper": "Dynamics", "Gate Divisor": "Dynamics", "Arpeggiator": "MIDI", "Drummer Pad 16": "Instrument", "Drummer Pad 48": "Instrument", "CatSynth": "Instrument", "EQ - 31 Band": "EQ"
    ]

    let theme: JarasInterfaceTheme
    let show: ShowController
    var samplersOnly = false
    var visibilityChanges: PassthroughSubject<Bool, Never>? = nil
    @ObservedObject private var instruments = InstrumentLibrary.shared
    #if os(macOS)
    @ObservedObject private var plugins = PluginCatalog.shared
    #endif
    @WorkspacePreference(LibraryNote.storageKey, store: WorkspaceLayoutPreferences.storage) private var storedNotes = Data()
    @WorkspacePreference("jaras.library.samplerCategories", store: WorkspaceLayoutPreferences.storage) private var storedSamplerCategories = Data()
    @WorkspacePreference("jaras.library.midiCategories", store: WorkspaceLayoutPreferences.storage) private var storedMIDICategories = Data()
    @WorkspacePreference("jaras.library.favorites", store: WorkspaceLayoutPreferences.storage) private var storedFavorites = Data()
    @WorkspacePreference("jaras.library.samplerPreviewDB", store: WorkspaceLayoutPreferences.storage) private var samplerPreviewDB = 0.0
    @State private var instrumentsExpanded = false
    @State private var pluginsExpanded = false
    @State private var samplersExpanded = false
    @State private var midiExpanded = false
    @State private var midiUserExpanded = false
    @State private var creatingMIDICategory = false
    @State private var midiFiles: [URL] = []
    @State private var importingMIDI = false
    @State private var midiImportError = ""
    @State private var userExpanded = false
    @State private var presetsExpanded = false
    @State private var favoritesExpanded = false
    @State private var annotationExpanded = false
    @State private var namingNote: LibraryNote?
    @State private var creatingCategory = false
    @State private var showingSamplerPicker = false
    @State private var showingFiles = false
    @StateObject private var files = WorkspaceFiles()
    @State private var categoryName = ""
    @State private var categoryToDelete: SamplerCategory?
    @State private var deletingPadSamples = false
    @State private var hasPadSamples = false
    @State private var categoryDeletionError: String?
    @State private var pickingSamplers = false
    @State private var samplerDestination: SamplerCategory?
    @State private var samplerFiles: [Sampler] = []
    @State private var samplerListRequest = UUID()
    @State private var samplerError = ""
    @State private var importingSamplers = false
    @State private var preview: (id: UUID, url: URL, instrumentID: String?)?
    @State private var previewPreparation: Task<Void, Never>?
    @State private var importingSoundFonts = false
    #if os(iOS)
    @State private var pickingSoundFonts = false
    #endif
    @State private var selection: Selection?
    @State private var searchText = ""
    @FocusState private var categorySearchFocused: Bool
    @State private var presets: [FXPreset] = []

    private static func pluginTypes(externalTypes: [String]) -> [String] {
        var categories = Set(Self.nativeTypes.values)
        categories.formUnion(externalTypes)
        return categories.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var pluginTypes: [String] {
        #if os(macOS)
        Self.pluginTypes(externalTypes: plugins.plugins.flatMap(\.types))
        #else
        Self.pluginTypes(externalTypes: [])
        #endif
    }
    struct PluginGroup {
        var title: String
        var entries: [(identity: String, name: String)]
    }
    static func mixerPluginGroups() -> [PluginGroup] {
        #if os(macOS)
        let catalog = PluginCatalog.shared
        let plugins = catalog.matchingPlugins(query: "", type: "", vendor: "", allowsInstruments: true)
        typealias Entry = (identity: String, name: String)
        var allExternal: [Entry] = []
        var externalByType: [String: [Entry]] = [:]
        for plugin in plugins {
            let entry = (identity: "vst3:" + plugin.classID, name: plugin.name)
            allExternal.append(entry)
            for type in Set(plugin.types) { externalByType[type, default: []].append(entry) }
        }
        let externalTypes = Array(externalByType.keys)
        #else
        let externalTypes: [String] = []
        #endif
        return (["All", "Native"] + pluginTypes(externalTypes: externalTypes)).map { title in
            var entries = (NativeFXSettings.order + [NativeFXSettings.waveLFOName]).compactMap { name -> (identity: String, name: String)? in
                guard let type = nativeTypes[name], title == "All" || title == "Native" || title == type else { return nil }
                return ("native:" + name, name == "Limiter" ? "CatLive Limiter" : name)
            }
            #if os(macOS)
            if title == "All" { entries += allExternal }
            else if title == PluginCatalog.favoritesType {
                entries += plugins.filter(catalog.isFavorite)
                    .map { ("vst3:" + $0.classID, $0.name) }
            } else if title != "Native" { entries += externalByType[title] ?? [] }
            #endif
            return PluginGroup(title: title, entries: entries)
        }
    }
    private var notes: [LibraryNote] { LibraryNote.decode(storedNotes) }
    private var samplerCategories: [SamplerCategory] {
        ((try? JSONDecoder().decode([SamplerCategory].self, from: storedSamplerCategories)) ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var samplerPickerEntries: [(name: String, target: Selection)] {
        var entries = samplerCategories.map { (name: $0.name, target: Selection.samplerCategory($0.id)) }
        entries.append(contentsOf: Self.voiceGuideCategories.map { (name: $0, target: .nativeSamplers($0)) })
        if hasPadSamples { entries.append((name: "Pads", target: .padSamplers)) }
        entries.append(contentsOf: Self.otherNativeSampleCategories.map { (name: $0, target: .nativeSamplers($0)) })
        return entries
    }
    private func nativeSamplerFolders(_ categories: [String]) -> some View {
        ForEach(Array(categories.enumerated()), id: \.element) { index, category in
            navigationRow(category, icon: "folder.fill", target: .nativeSamplers(category),
                          shaded: index.isMultiple(of: 2))
        }
    }

    private var favoriteKeys: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: storedFavorites)) ?? [])
    }
    private var presetPlugins: [String] {
        Set(presets.map(\.plugin)).sorted { pluginName($0).localizedStandardCompare(pluginName($1)) == .orderedAscending }
    }

    private var folders: some View {
        VStack(spacing: 0) {
            folderToolbar
            LibraryScrollView {
                VStack(spacing: 2) {
                    folder("Instruments", expanded: $instrumentsExpanded, shaded: false, icon: "library.instruments")
                        .contextMenu {
                            Button("Import SF2…", action: chooseSoundFonts).disabled(importingSoundFonts)
                        }
                    if instrumentsExpanded {
                        ForEach(Array(InstrumentCategory.allCases.enumerated()), id: \.element) { index, category in
                            navigationRow(category.displayName,
                                          icon: "folder.fill", target: .instrument(category), shaded: index.isMultiple(of: 2))
                        }
                    }
                    Divider().padding(.vertical, 3)
                    folder("Plugins", expanded: $pluginsExpanded, shaded: true, icon: "library.plugins")
                        #if os(macOS)
                        .contextMenu {
                            Button("Scan Plugins") {
                                NotificationCenter.default.post(name: .catLiveOpenPluginSettings, object: show)
                            }
                        }
                        #endif
                    if pluginsExpanded {
                        navigationRow("All", icon: "square.grid.2x2", target: .plugins(nil), shaded: false)
                        navigationRow("Native", icon: "folder.fill", target: .plugins("Native"), shaded: true)
                        ForEach(Array(pluginTypes.enumerated()), id: \.element) { index, type in
                            navigationRow(type, icon: "folder.fill", target: .plugins(type), shaded: index.isMultiple(of: 2))
                        }
                    }
                    Divider().padding(.vertical, 3)
                    folder("Samplers", expanded: $samplersExpanded, shaded: false, icon: "library.samplers")
                    if samplersExpanded {
                        folder("User", expanded: $userExpanded, shaded: true)
                            .contextMenu {
                                Button("Create category") {
                                    categoryName = ""
                                    creatingCategory = true
                                }
                            }
                            .popover(isPresented: $creatingCategory, arrowEdge: .trailing) {
                                categoryInput()
                            }
                        if userExpanded {
                            ForEach(Array(samplerCategories.enumerated()), id: \.element.id) { index, category in
                                navigationRow(category.name, icon: "folder.fill", target: .samplerCategory(category.id),
                                              shaded: index.isMultiple(of: 2))
                                    .onDrop(of: [UTType.fileURL], isTargeted: nil) { dropSamplers($0, into: category) }
                                    .contextMenu {
                                        Button("Add Samplers") {
                                            selection = .samplerCategory(category.id)
                                            samplerDestination = category
                                            pickingSamplers = true
                                        }.disabled(importingSamplers || pickingSamplers)
                                        Button("Delete", role: .destructive) { categoryToDelete = category }
                                            .disabled(importingSamplers || pickingSamplers)
                                    }
                            }
                        }
                        nativeSamplerFolders(Self.voiceGuideCategories)
                        if hasPadSamples {
                            navigationRow("Pads", icon: "folder.fill", target: .padSamplers, shaded: true)
                                .contextMenu { Button("Delete", role: .destructive) { deletingPadSamples = true } }
                        }
                        nativeSamplerFolders(Self.otherNativeSampleCategories)
                    }
                    divider
                    folder("Midi", expanded: $midiExpanded, shaded: true, icon: "pianokeys")
                    if midiExpanded {
                        folder("User", expanded: $midiUserExpanded, shaded: false)
                            .contextMenu { Button("Create category") { categoryName = ""; creatingMIDICategory = true } }
                            .popover(isPresented: $creatingMIDICategory, arrowEdge: .trailing) { categoryInput(midi: true) }
                        if midiUserExpanded {
                            ForEach(midiCategories) { category in
                                navigationRow(category.name, icon: "folder.fill", target: .midiCategory(category.id), shaded: false)
                                    .onDrop(of: [.midi, .fileURL], isTargeted: nil) { dropMIDI($0, into: category.id) }
                            }
                        }
                        ForEach(LibraryMIDIChord.categories, id: \.self) { category in
                            navigationRow(category, icon: "folder.fill", target: .midiChords(category), shaded: false)
                        }
                    }
                    divider
                    folder("Presets", expanded: $presetsExpanded, shaded: false, icon: "library.presets")
                    if presetsExpanded {
                        ForEach(Array(presetPlugins.enumerated()), id: \.element) { index, plugin in
                            navigationRow(pluginName(plugin), icon: "folder.fill", target: .preset(plugin),
                                          shaded: index.isMultiple(of: 2))
                        }
                    }
                    folder("Favorites", expanded: $favoritesExpanded, shaded: true, icon: "star.fill")
                    if favoritesExpanded {
                        navigationRow("Plugins", icon: "folder.fill", target: .favoritePlugins, shaded: false)
                        navigationRow("Samplers", icon: "folder.fill", target: .favoriteSamplers, shaded: true)
                    }
                    divider
                    folder("Notes", expanded: $annotationExpanded, shaded: false, icon: "note.text")
                        .contextMenu {
                            Button("New note") { namingNote = LibraryNote() }
                        }
                        .popover(item: $namingNote, arrowEdge: .trailing) { note in
                            LibraryNoteNameInput(note: note) { name in
                                saveNotes(LibraryNote.saving(note, name: name, in: notes))
                                annotationExpanded = true
                                selection = .annotation(note.id)
                                namingNote = nil
                            }
                        }
                    if annotationExpanded {
                        ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                            navigationRow(note.title, icon: "doc.text", target: .annotation(note.id),
                                          shaded: index.isMultiple(of: 2))
                                .contextMenu {
                                    Button("Rename note") { namingNote = note }
                                    Button("Delete note", role: .destructive) {
                                        saveNotes(notes.filter { $0.id != note.id })
                                        if selection == .annotation(note.id) { selection = nil }
                                    }
                                }
                        }
                    }
                    divider
                    navigationRow("Region", icon: "rectangle", target: .regions, shaded: false)
                    navigationRow("Markers", icon: "flag", target: .markers, shaded: true)
                }
                .padding(6)
            }
        }
    }

    var body: some View {
        Group {
            if samplersOnly {
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        samplerPaneTab("Samplers", filesTab: false)
                        samplerPaneTab("Files", filesTab: true)
                    }.padding(5)
                    Divider()
                    if showingFiles {
                        WorkspaceFilesPane(files: files, theme: theme)
                    } else {
                        samplerToolbar
                        samplerDropArea(details)
                    }
                }
            } else {
                LibraryColumns(theme: theme, folders: folders, entries: VStack(spacing: 0) {
                    if showsSearch && selection != .regions && selection != .markers { searchField }
                    #if os(iOS)
                    details.fileImporter(isPresented: $pickingSoundFonts, allowedContentTypes: [UTType(filenameExtension: "sf2") ?? .data],
                                         allowsMultipleSelection: true, onCompletion: importSoundFonts)
                    #else
                    samplerDropArea(details)
                    #endif
                })
            }
        }
        .background(theme.mixerPanelBackground)
        .foregroundStyle(JarasTheme.text)
        .accessibilityIdentifier("workspace-library-panel")
        // Prepare each catalog when its folder is visible. Opening a collapsed
        // Library during playback should only mount its navigation controls.
        .task(id: samplersOnly || samplersExpanded) {
            guard samplersOnly || samplersExpanded else { return }
            refreshPadSamples()
            if samplersOnly && selection == nil {
                selection = samplerPickerEntries.first?.target
            }
        }
        .task(id: instrumentsExpanded) { if instrumentsExpanded { instruments.refresh() } }
        .task(id: presetsExpanded) { if presetsExpanded { loadPresets() } }
        .onReceive(show.libraryTimelineSelection.openedPane) { pane in
            if pane == .dock && (selection == .regions || selection == .markers) { selection = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: VinhetasController.padSamplesChanged)) { _ in refreshPadSamples() }
        .onDisappear { stopPreview() }
        .onReceive(visibilityChanges?.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { visible in
            if !visible { stopPreview() }
            else if samplersOnly {
                refreshPadSamples()
                if !samplerPickerEntries.contains(where: { $0.target == selection }) {
                    selection = samplerPickerEntries.first?.target
                } else if selection != .padSamplers && selection != .favoriteSamplers {
                    loadSamplers()
                }
            }
        }
        .onChange(of: samplerPreviewDB) { _ in
            if let preview, preview.instrumentID == nil { projectAudio.setPadGain(preview.id, gain: samplerPreviewGain) }
        }
        .onChange(of: instruments.downloaded) { available in
            if let id = preview?.instrumentID, !available.contains(id) { stopPreview() }
        }
        .onReceive(NotificationCenter.default.publisher(for: FXPresetStore.didChange)) { notification in
            if notification.object as? URL == FXPresetStore.shared.url { loadPresets() }
        }
        .fileImporter(isPresented: $pickingSamplers, allowedContentTypes: [.audio], allowsMultipleSelection: true,
                      onCompletion: importSamplers)
        .confirmationDialog("Delete category?", isPresented: Binding(
            get: { categoryToDelete != nil }, set: { if !$0 { categoryToDelete = nil } }),
            titleVisibility: .visible, presenting: categoryToDelete) { category in
                Button("Delete", role: .destructive) { deleteCategory(category) }
            } message: { category in
                Text("Remove \(category.name) and its samples from the Library?")
            }
        .confirmationDialog("Delete Pads?", isPresented: $deletingPadSamples, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: deletePadSamples)
        } message: {
            Text("Delete these samples and clear them from all Pads that use them?")
        }
        .alert("Library", isPresented: Binding(
            get: { categoryDeletionError != nil }, set: { if !$0 { categoryDeletionError = nil } })) {
                Button("OK") { categoryDeletionError = nil }
            } message: { Text(verbatim: categoryDeletionError ?? "") }
        .onChange(of: selection) { _ in
            searchText = ""
            if preview?.instrumentID != nil { stopPreview() }
        }
        .task(id: selection) {
            switch selection {
            case .samplerCategory, .padSamplers, .nativeSamplers, .favoriteSamplers:
                samplerFiles = []; loadSamplers()
            case .midiCategory(let id):
                midiFiles = []; midiImportError = ""
                await loadMIDI(id)
            default: break
            }
        }
    }

    private func samplerPaneTab(_ title: LocalizedStringKey, filesTab: Bool) -> some View {
        let selected = showingFiles == filesTab
        return Button {
            guard !selected else { return }
            stopPreview()
            showingSamplerPicker = false
            showingFiles = filesTab
        } label: {
            Text(title).font(.jarasSystem(size: 11, weight: .semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 23)
                .foregroundStyle(selected ? Color.black : JarasTheme.text)
                .background(selected ? JarasTheme.green : theme.panel, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var folderToolbar: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                instrumentsExpanded = false
                pluginsExpanded = false
                samplersExpanded = false
                midiExpanded = false
                midiUserExpanded = false
                userExpanded = false
                presetsExpanded = false
                favoritesExpanded = false
                annotationExpanded = false
            } label: {
                ControlIcon(name: "arrow.up.and.down.text.horizontal",
                            active: instrumentsExpanded || pluginsExpanded || samplersExpanded || midiExpanded || presetsExpanded || favoritesExpanded || annotationExpanded)
                    .frame(width: 25, height: 23)
                    .background(theme.display, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse all categories")
            .accessibilityIdentifier("library-collapse-categories")
            .jarasHelp("Collapse all categories")
        }
        .padding(.horizontal, 6).frame(height: 32)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.opacity(0.65)).frame(height: 1) }
    }

    private var divider: some View {
        Rectangle().fill(theme.line.opacity(0.65)).frame(height: 1).padding(.vertical, 5)
    }

    private func folder(_ name: String, expanded: Binding<Bool>, shaded: Bool,
                        icon: String = "folder.fill") -> some View {
        Button {
            expanded.wrappedValue.toggle()
        } label: {
            row(name, icon: icon, chevron: expanded.wrappedValue ? "chevron.down" : "chevron.right",
                shaded: shaded)
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded.wrappedValue ? Text("Expanded") : Text("Collapsed"))
    }

    private func navigationRow(_ name: String, icon: String, target: Selection, shaded: Bool) -> some View {
        Button {
            selection = target
            if target == .regions || target == .markers {
                show.libraryTimelineSelection.openedPane.send(.library)
            }
        } label: {
            row(name, icon: icon, chevron: nil, shaded: shaded, selected: selection == target)
        }.buttonStyle(.plain)
    }

    private func row(_ name: String, icon: String, chevron: String?, shaded: Bool, selected: Bool = false) -> some View {
        HStack(spacing: 6) {
            if let chevron {
                Image(systemName: chevron).font(.jarasSystem(size: 9, weight: .semibold))
                    .foregroundStyle(theme.secondary).frame(width: 11)
            } else {
                Color.clear.frame(width: 11)
            }
            if icon == "folder.fill" || icon.hasPrefix("library.") {
                Image(systemName: "folder.fill").font(.jarasSystem(size: 12))
                    .foregroundStyle(JarasTheme.green).frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            } else {
                ControlIcon(name: icon, active: selected || chevron == "chevron.down", size: 16)
            }
            Text(verbatim: name).font(.jarasSystem(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(height: 25)
        .background(rowFill(shaded: shaded, selected: selected), in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }

    private func rowFill(shaded: Bool, selected: Bool = false) -> Color {
        selected ? JarasTheme.green.opacity(0.20) : .white.opacity(shaded ? 0.045 : 0)
    }

    private var showsSearch: Bool {
        guard let selection else { return false }
        if case .annotation = selection { return false }
        return true
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.jarasSystem(size: 11)).foregroundStyle(theme.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.jarasSystem(size: 12))
                .focused($categorySearchFocused)
                .accessibilityIdentifier("library-category-search")
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
        #if os(macOS)
        .background(FieldOutsideClick(active: categorySearchFocused, includesOtherWindows: true) {
            categorySearchFocused = false
        })
        #endif
        .padding(.horizontal, 6)
        .frame(height: 32)
    }

    private func matchesSearch(_ name: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || name.localizedStandardContains(query)
    }

    @ViewBuilder private var details: some View {
        switch selection {
        case .instrument(let category):
            instrumentList(category)
        case .plugins(let type):
            pluginList(type: type)
        case .samplerCategory, .padSamplers, .nativeSamplers, .favoriteSamplers:
            samplerList
        case .midiCategory(let id):
            midiList(id)
        case .midiChords(let category):
            LibraryScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(LibraryMIDIChord.catalog.filter { $0.category == category && matchesSearch($0.name) }, id: \.name) { chord in
                        HStack(spacing: 6) {
                            ControlIcon(name: "pianokeys", size: 13)
                            Text(verbatim: chord.name)
                            Spacer()
                        }.font(.jarasSystem(size: 12, weight: .medium))
                            .padding(.horizontal, 8).frame(height: 27).contentShape(Rectangle())
                            .modifier(LibraryRowDrag(title: chord.name, type: UTType(exportedAs: LibraryMIDIChord.transferType),
                                data: { Data(chord.name.utf8) }, provider: {
                                    NSItemProvider(item: Data(chord.name.utf8) as NSData, typeIdentifier: LibraryMIDIChord.transferType)
                                }))
                    }
                }
            }
        case .preset(let plugin):
            presetList(plugin)
        case .favoritePlugins:
            pluginList(favoritesOnly: true)
        case .annotation(let note):
            annotation(note)
        case .regions, .markers:
            LibraryTimelineList(show: show, regions: selection == .regions, docked: false)
                .id(selection)
        case nil:
            Color.clear
        }
    }

    private func chooseSoundFonts() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = JarasLocalization.string("Import SF2…")
        panel.allowedContentTypes = [UTType(filenameExtension: "sf2") ?? .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { result in
            if result == .OK { importSoundFonts(.success(panel.urls)) }
        }
        #else
        pickingSoundFonts = true
        #endif
    }

    private func importSoundFonts(_ result: Result<[URL], Error>) {
        guard case .success(let files) = result, !files.isEmpty else { return }
        instrumentsExpanded = true
        selection = .instrument(.user)
        searchText = ""
        importingSoundFonts = true
        Task {
            await instruments.importSoundFonts(files)
            importingSoundFonts = false
        }
    }

    private func instrumentList(_ category: InstrumentCategory) -> some View {
        let entries = instruments.entries.filter { $0.category == category && matchesSearch($0.name) }
        return VStack(alignment: .leading, spacing: 0) {
            LibraryScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, instrument in
                        instrumentRow(instrument, shaded: index.isMultiple(of: 2))
                    }
                }.padding(6)
            }
            if importingSoundFonts { ProgressView().controlSize(.small).padding(8) }
            if !instruments.error.isEmpty {
                Text(verbatim: instruments.error).font(.jarasCaption).foregroundStyle(.red).padding(8)
            }
        }
    }

    private func instrumentRow(_ instrument: LibraryInstrument, shaded: Bool) -> some View {
        let available = instruments.downloaded.contains(instrument.id)
        return HStack(spacing: 6) {
            entryName(instrument.name, icon: "pianokeys")
                .contentShape(Rectangle())
                .modifier(effectDrag(instrument.name, identity: "native:Instruments:" + instrument.id))
            if available {
                    let playing = preview?.instrumentID == instrument.id
                    Button {
                        if let file = instruments.previewFile(instrument) { togglePreview(file, instrumentID: instrument.id) }
                    } label: {
                        instrumentActionIcon(playing ? "stop.fill" : "play.fill")
                            .foregroundStyle(playing ? JarasTheme.green : JarasTheme.text)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playing ? Text("Stop") : Text("Play"))
                    .accessibilityIdentifier("library-preview-" + instrument.id)
            } else {
                if let progress = instruments.progress[instrument.id] {
                    instrumentDownloadProgress(progress)
                } else {
                    Button { instruments.download(instrument.id) } label: {
                        instrumentActionIcon("arrow.down")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Download"))
                    .accessibilityIdentifier("library-download-" + instrument.id)
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 27)
        .background(rowFill(shaded: shaded), in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .contextMenu {
            if instruments.installed.contains(instrument.id) {
                Button("Delete instrument", role: .destructive) { instruments.uninstall(instrument.id) }
            }
        }
    }

    private func instrumentDownloadProgress(_ fraction: Double) -> some View {
        let known = fraction > 0
        return TimelineView(.animation(minimumInterval: 1.0 / 24, paused: known)) { timeline in
            let rotation = known ? -90 : timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1) * 360 - 90
            ZStack {
                Circle().strokeBorder(.white.opacity(0.15), lineWidth: 2)
                Circle().trim(from: 0, to: known ? max(0.05, min(1, fraction)) : 0.28)
                    .stroke(JarasTheme.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .padding(1)
                    .rotationEffect(.degrees(rotation))
            }
        }
        .frame(width: 19, height: 19)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Download"))
        .accessibilityValue(Text(verbatim: known ? "\(Int(min(1, fraction) * 100))%" : ""))
    }

    private func instrumentActionIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.jarasSystem(size: 9, weight: .semibold))
            .frame(width: 19, height: 19)
            .background(.white.opacity(0.09), in: Circle())
            .contentShape(Circle())
    }

    private func entryName(_ name: String, icon: String) -> some View {
        HStack(spacing: 6) {
            if icon == "waveform" { TransportControlIcon(name: icon, size: 12, color: theme.secondary) }
            else { Image(systemName: icon).font(.jarasSystem(size: 11, weight: .medium)).foregroundStyle(theme.secondary) }
            Text(verbatim: name).font(.jarasSystem(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func pluginList(type: String? = nil, favoritesOnly: Bool = false) -> some View {
        #if os(macOS)
        let external = type == "Native" ? [] : plugins.matchingPlugins(query: "", type: favoritesOnly ? PluginCatalog.favoritesType : type ?? "",
                                               vendor: "", allowsInstruments: true).filter { matchesSearch($0.name) }
        #endif
        let native = (NativeFXSettings.order + [NativeFXSettings.waveLFOName]).filter {
            guard let category = Self.nativeTypes[$0], matchesSearch(pluginName("native:" + $0)) else { return false }
            if favoritesOnly { return favoriteKeys.contains("native:" + $0) }
            return type == nil || type == "Native" || category == type
        }
        return LibraryScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(native.enumerated()), id: \.element) { index, name in
                    let key = "native:" + name
                    pluginRow(pluginName(key), identity: key, shaded: index.isMultiple(of: 2),
                              favorite: favoriteKeys.contains(key), format: "Native") { toggleFavorite(key) }
                }
                #if os(macOS)
                ForEach(Array(external.enumerated()), id: \.element.id) { index, plugin in
                    pluginRow(plugin.name, identity: "vst3:" + plugin.classID, shaded: (native.count + index).isMultiple(of: 2),
                              favorite: plugins.isFavorite(plugin), format: plugin.formatBadge) { plugins.toggleFavorite(plugin) }
                }
                #endif
            }
            .padding(6)
        }
    }

    private func pluginRow(_ name: String, identity: String, shaded: Bool, favorite: Bool,
                           format: String, toggle: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            entryName(name, icon: "puzzlepiece.extension")
                .contentShape(Rectangle())
                .modifier(effectDrag(name, identity: identity))
            Text(verbatim: format)
                .font(.jarasSystem(size: 9, weight: .semibold))
                .foregroundStyle(format == "ARA2" ? JarasTheme.green : theme.secondary)
                .fixedSize().padding(.horizontal, 4).padding(.vertical, 2)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
            favoriteButton(favorite, action: toggle)
        }
            .padding(.horizontal, 6).frame(height: 27)
            .background(rowFill(shaded: shaded), in: RoundedRectangle(cornerRadius: 5))
    }
    private func libraryEffect(_ identity: String, presetID: String? = nil) -> FooterEffectTransfer {
        FooterEffectTransfer(project: show.snapshot.project.id, source: nil, effect: identity, library: true, presetID: presetID)
    }
    private func effectDrag(_ title: String, identity: String, presetID: String? = nil) -> LibraryRowDrag {
        let transfer = libraryEffect(identity, presetID: presetID)
        return LibraryRowDrag(title: title, type: transfer.contentType,
            data: { try? JSONEncoder().encode(transfer) }, provider: { transfer.provider })
    }

    private func favoriteButton(_ favorite: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TransportControlIcon(name: favorite ? "star.fill" : "star", size: 11,
                                 color: favorite ? JarasTheme.yellow : theme.secondary)
                .frame(width: 19, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(favorite ? Text("Remove from favorites") : Text("Add to favorites"))
    }

    private func toggleFavorite(_ key: String) {
        var updated = favoriteKeys
        if !updated.insert(key).inserted { updated.remove(key) }
        if let encoded = try? JSONEncoder().encode(updated.sorted()) { storedFavorites = encoded }
        if selection == .favoriteSamplers { loadSamplers() }
    }

    private func pluginName(_ identity: String) -> String {
        if identity == "native:Limiter" { return "CatLive Limiter" }
        if identity.hasPrefix("native:Instruments:") {
            return InstrumentLibrary.displayName(String(identity.dropFirst("native:Instruments:".count)))
        }
        if identity.hasPrefix("native:") { return String(identity.dropFirst("native:".count)) }
        #if os(macOS)
        if identity.hasPrefix("vst3:") {
            let id = String(identity.dropFirst("vst3:".count))
            return plugins.plugins.first { $0.classID.caseInsensitiveCompare(id) == .orderedSame }?.name ?? id
        }
        #endif
        return identity
    }

    private func loadPresets() {
        presets = ((try? FXPresetStore.shared.read())?.presets ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func presetList(_ plugin: String) -> some View {
        let name = pluginName(plugin)
        let entries = presets.filter { $0.plugin == plugin && matchesSearch("\(name) - \($0.name)") }
        return LibraryScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, preset in
                    entryName("\(name) - \(preset.name)", icon: "slider.horizontal.3")
                        .padding(.horizontal, 6).frame(height: 27)
                        .background(rowFill(shaded: index.isMultiple(of: 2)), in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle()).modifier(effectDrag("\(name) - \(preset.name)", identity: plugin, presetID: preset.id))
                }
            }.padding(6)
        }
    }

    @ViewBuilder private func annotation(_ id: UUID) -> some View {
        if let note = notes.first(where: { $0.id == id }) {
            EditableLibraryNote(note: note) {
                Text(verbatim: note.title)
                    .font(.jarasSystem(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .padding(.leading, 6)
            }
            .id(id)
        }
    }

    private func saveNotes(_ updated: [LibraryNote]) {
        if let encoded = try? JSONEncoder().encode(updated) { storedNotes = encoded }
    }

    private var samplerTitle: String {
        switch selection {
        case .samplerCategory(let id): return samplerCategories.first { $0.id == id }?.name ?? JarasLocalization.string("Samplers")
        case .nativeSamplers(let name): return name
        case .padSamplers: return "Pads"
        default: return JarasLocalization.string("Samplers")
        }
    }

    private var samplerToolbar: some View {
        LibraryDockPickerButton(title: "Sampler categories", current: samplerTitle) {
            creatingCategory = false
            showingSamplerPicker.toggle()
        }.padding(5)
        .popover(isPresented: $showingSamplerPicker, arrowEdge: .bottom) {
            if creatingCategory { categoryInput() }
            else {
                let entries = samplerPickerEntries
                LibraryDockPickerList(rowCount: entries.count + 1, hasSeparator: !entries.isEmpty) {
                    LibraryDockPickerRow(title: JarasLocalization.string("Create")) {
                        categoryName = ""
                        creatingCategory = true
                    }
                    if !entries.isEmpty { LibraryDockPickerList<EmptyView>.separator }
                    ForEach(entries, id: \.target) { entry in
                        LibraryDockPickerRow(title: entry.name, selected: selection == entry.target) {
                            selection = entry.target
                            showingSamplerPicker = false
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func samplerDropArea<V: View>(_ view: V) -> some View {
        if case .samplerCategory(let id) = selection, let category = samplerCategories.first(where: { $0.id == id }) {
            view.onDrop(of: [UTType.fileURL], isTargeted: nil) { dropSamplers($0, into: category) }
        } else {
            view
        }
    }

    private func dropSamplers(_ providers: [NSItemProvider], into category: SamplerCategory) -> Bool {
        let candidates = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !candidates.isEmpty, !importingSamplers, !pickingSamplers else { return false }
        selection = .samplerCategory(category.id)
        importingSamplers = true
        Task { @MainActor in
            var urls: [URL] = []
            for provider in candidates {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: NSURL.self) { item, _ in
                        continuation.resume(returning: (item as? NSURL).map { $0 as URL })
                    }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            importingSamplers = false
            importSamplers(urls, into: category)
        }
        return true
    }

    private func categoryInput(midi: Bool = false) -> some View {
        let name = categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = !name.isEmpty && !(midi ? midiCategories : samplerCategories).contains { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Create category").font(.jarasSystem(size: 13, weight: .semibold))
            TextField("Name", text: $categoryName)
                .onChange(of: categoryName) { name in
                    if name.count > 12 { categoryName = String(name.prefix(12)) }
                }
                .onSubmit { if valid { createCategory(name, midi: midi) } }
            Button("Create") { createCategory(name, midi: midi) }.disabled(!valid)
        }.padding(12).frame(width: 195)
    }

    private func createCategory(_ name: String, midi: Bool) {
        let category = SamplerCategory(name: String(name.prefix(12)))
        if midi {
            guard let encoded = try? JSONEncoder().encode(midiCategories + [category]) else { return }
            storedMIDICategories = encoded
            midiUserExpanded = true
            selection = .midiCategory(category.id)
            creatingMIDICategory = false
            return
        }
        guard let encoded = try? JSONEncoder().encode(samplerCategories + [category]) else { return }
        storedSamplerCategories = encoded
        userExpanded = true
        selection = .samplerCategory(category.id)
        creatingCategory = false
        showingSamplerPicker = false
    }

    private var midiCategories: [SamplerCategory] {
        ((try? JSONDecoder().decode([SamplerCategory].self, from: storedMIDICategories)) ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func midiList(_ id: UUID) -> some View {
        VStack(spacing: 0) {
            LibraryScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(midiFiles.filter { matchesSearch($0.deletingPathExtension().lastPathComponent) }, id: \.self) { url in
                        HStack(spacing: 6) {
                            ControlIcon(name: "pianokeys", size: 13)
                            Text(verbatim: url.deletingPathExtension().lastPathComponent).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 8).frame(height: 27)
                        .contentShape(Rectangle())
                        .onDrag { NSItemProvider(object: url as NSURL) }
                    }
                }
            }
            if importingMIDI { ProgressView().controlSize(.small).padding(8) }
            if !midiImportError.isEmpty {
                Text(verbatim: midiImportError).font(.jarasCaption).foregroundStyle(.red).padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.midi, .fileURL], isTargeted: nil) { dropMIDI($0, into: id) }
        .background {
            LibraryKeyboardArea { code in
                guard code == 9 else { return false }
                pasteMIDI(into: id)
                return true
            }
        }
    }

    private func loadMIDI(_ id: UUID) async {
        let files = await LibraryMIDIStorage.shared.files(in: id)
        if !Task.isCancelled && selection == .midiCategory(id) { midiFiles = files }
    }

    private func pasteMIDI(into id: UUID) {
        #if os(macOS)
        let clipboard = GridMediaClipboard.shared
        let items: GridItemClipboard?
        switch clipboard.source() {
        case .items: items = clipboard.items
        case .files(let urls):
            importMIDI(into: id) { await LibraryMIDIStorage.shared.copy(urls, into: id) }
            return
        default: items = nil
        }
        #else
        let items = show.copiedGridItems
        #endif
        let clips = items?.moving == false ? items?.entries.map(\.clip).filter { $0.midi != nil } ?? [] : []
        guard !clips.isEmpty else {
            midiImportError = JarasLocalization.string("Copy one or more MIDI items first.")
            return
        }
        importMIDI(into: id) { await LibraryMIDIStorage.shared.export(clips, into: id) }
    }

    private func dropMIDI(_ providers: [NSItemProvider], into id: UUID) -> Bool {
        guard !providers.isEmpty, !importingMIDI else { return false }
        selection = .midiCategory(id)
        importMIDI(into: id) {
            var failures: [String] = []
            for provider in providers {
                do {
                    let (name, data) = try await Self.readDroppedMIDI(provider)
                    try await LibraryMIDIStorage.shared.saveFile(data, named: name, into: id)
                } catch { failures.append(error.localizedDescription) }
            }
            return failures
        }
        return true
    }

    private func importMIDI(into id: UUID, using work: @escaping @MainActor () async -> [String]) {
        guard !importingMIDI else { return }
        importingMIDI = true
        midiImportError = ""
        Task { @MainActor in
            let failures = await work()
            importingMIDI = false
            guard selection == .midiCategory(id) else { return }
            await loadMIDI(id)
            if selection == .midiCategory(id) { midiImportError = failures.joined(separator: "\n") }
        }
    }

    nonisolated private static func readDroppedMIDI(_ provider: NSItemProvider) async throws -> (String, Data) {
        let result: Result<(String, Data), Error> = await withCheckedContinuation { continuation in
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: NSURL.self) { item, error in
                    continuation.resume(returning: Result {
                        guard let url = (item as? NSURL).map({ $0 as URL }) else {
                            throw error ?? ProjectError.invalid("Invalid MIDI file.")
                        }
                        return (url.deletingPathExtension().lastPathComponent, try LibraryMIDIStorage.read(url))
                    })
                }
            } else {
                let suggestedName = provider.suggestedName
                _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.midi.identifier) { url, error in
                    continuation.resume(returning: Result {
                        guard let url else { throw error ?? ProjectError.invalid("Invalid MIDI file.") }
                        let name = suggestedName.map { ($0 as NSString).deletingPathExtension } ?? url.deletingPathExtension().lastPathComponent
                        return (name, try LibraryMIDIStorage.read(url, checkExtension: false))
                    })
                }
            }
        }
        return try result.get()
    }

    private func deleteCategory(_ category: SamplerCategory) {
        guard !importingSamplers, !pickingSamplers, !Self.categoriesImporting.contains(category.id),
              samplerCategories.contains(where: { $0.id == category.id }) else { return }
        do {
            let categories = try JSONEncoder().encode(samplerCategories.filter { $0.id != category.id })
            let prefix = category.id.uuidString + "/"
            let favorites = try JSONEncoder().encode(favoriteKeys.filter { !$0.hasPrefix(prefix) }.sorted())
            let directory = try Self.samplerDirectory(category.id)
            if preview?.url.deletingLastPathComponent() == directory { stopPreview() }
            if FileManager.default.fileExists(atPath: directory.path) {
                #if os(macOS)
                try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
                #else
                try FileManager.default.removeItem(at: directory)
                #endif
            }
            storedSamplerCategories = categories
            storedFavorites = favorites
            if selection == .samplerCategory(category.id) { selection = nil }
            loadSamplers()
        } catch {
            categoryDeletionError = error.localizedDescription
        }
    }

    private static func samplerDirectory(_ id: UUID) throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("JarasLive/Samplers", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func refreshPadSamples() {
        let files = try? FileManager.default.contentsOfDirectory(at: VinhetasController.shared.padSampleDirectory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        hasPadSamples = files?.contains {
            VinhetasPad.accepts($0) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        } ?? false
        if !hasPadSamples && selection == .padSamplers { selection = nil }
        if selection == .padSamplers || selection == .favoriteSamplers { loadSamplers() }
    }

    private func padSamplers() -> [Sampler] {
        Self.samplers(in: VinhetasController.shared.padSampleDirectory).filter { VinhetasPad.accepts($0.url) }
    }

    private func deletePadSamples() {
        do {
            let samples = padSamplers()
            let removed = Set(samples.map(\.favoriteKey))
            let favorites = try JSONEncoder().encode(favoriteKeys.subtracting(removed).sorted())
            if let preview, samples.contains(where: { $0.url == preview.url }) { stopPreview() }
            try VinhetasController.shared.deletePadSamples()
            storedFavorites = favorites
        } catch { categoryDeletionError = error.localizedDescription }
    }

    private func loadSamplers() {
        let token = UUID()
        samplerListRequest = token
        samplerError = ""
        let requested = selection
        var folders: [(url: URL, audioOnly: Bool)] = []
        var favorites: Set<String>?
        switch requested {
        case .samplerCategory(let id):
            if let folder = try? Self.samplerDirectory(id) { folders.append((folder, false)) }
        case .padSamplers:
            folders.append((VinhetasController.shared.padSampleDirectory, true))
        case .nativeSamplers(let name):
            if let root = Self.nativeSampleRoot { folders.append((root.appendingPathComponent(name), true)) }
        case .favoriteSamplers:
            favorites = favoriteKeys
            folders = samplerCategories.compactMap { category in
                (try? Self.samplerDirectory(category.id)).map { ($0, false) }
            }
            folders.append((VinhetasController.shared.padSampleDirectory, true))
            if let root = Self.nativeSampleRoot {
                folders += Self.nativeSampleCategories.map { (root.appendingPathComponent($0), true) }
            }
        default:
            samplerFiles = []
            return
        }
        Task { @MainActor [folders, favorites] in
            let files = await Task.detached(priority: .userInitiated) {
                let entries = folders.flatMap { folder in
                    Self.samplers(in: folder.url).filter { !folder.audioOnly || VinhetasPad.accepts($0.url) }
                }
                guard let favorites else { return entries }
                return entries.filter { favorites.contains($0.favoriteKey) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }.value
            guard samplerListRequest == token, selection == requested else { return }
            samplerFiles = files
        }
    }

    nonisolated private static func samplers(in directory: URL?) -> [Sampler] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map(Sampler.init(url:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var samplerList: some View {
        let favorites = favoriteKeys
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ControlIcon(name: "speaker.wave.2", size: 14)
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    LibraryPreviewGainKnob(value: $samplerPreviewDB)
                    Text(verbatim: samplerPreviewDB <= -60 ? "−∞ dB" : String(format: "%.0f dB", samplerPreviewDB))
                        .font(.jarasSystem(size: 10)).monospacedDigit().lineLimit(1)
                        .frame(width: 36, alignment: .leading)
                }
            }.padding(.horizontal, 6).frame(height: 32)
            LibraryScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(samplerFiles.filter { matchesSearch($0.name) }.enumerated()), id: \.element.id) { index, sampler in
                        let playing = preview?.url == sampler.url
                        HStack(spacing: 0) {
                            Button { togglePreview(sampler.url) } label: {
                                HStack(spacing: 0) {
                                    entryName(sampler.name, icon: "waveform").padding(.leading, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    TransportControlIcon(name: playing ? "stopall" : "play", size: 11,
                                                         color: playing ? JarasTheme.green : theme.secondary)
                                        .frame(width: 24)
                                }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel(Text(verbatim: sampler.name))
                                .accessibilityHint(playing ? Text("Stop") : Text("Play"))
                                .modifier(LibraryRowDrag(title: sampler.name, type: LibrarySamplerTransfer.type,
                                    data: { Data(sampler.url.absoluteString.utf8) },
                                    provider: { LibrarySamplerTransfer.provider(sampler.url) },
                                    click: { togglePreview(sampler.url) }))
                            favoriteButton(favorites.contains(sampler.favoriteKey)) { toggleFavorite(sampler.favoriteKey) }
                                .padding(.trailing, 6)
                        }
                        .frame(height: 27)
                        .background(rowFill(shaded: index.isMultiple(of: 2)), in: RoundedRectangle(cornerRadius: 5))
                    }
                }.padding(6)
            }
            if importingSamplers { ProgressView().controlSize(.small).padding(8) }
            if !samplerError.isEmpty {
                Text(verbatim: samplerError).font(.jarasCaption).foregroundStyle(.red).padding(8)
            }
        }
    }

    private func importSamplers(_ result: Result<[URL], Error>) {
        guard let category = samplerDestination else { return }
        samplerDestination = nil
        do { importSamplers(try result.get(), into: category) }
        catch { samplerError = error.localizedDescription }
    }

    private func importSamplers(_ urls: [URL], into category: SamplerCategory) {
        guard !urls.isEmpty, !importingSamplers, !Self.categoriesImporting.contains(category.id),
              samplerCategories.contains(where: { $0.id == category.id }) else { return }
        let directory: URL
        do { directory = try Self.samplerDirectory(category.id) }
        catch { samplerError = error.localizedDescription; return }
        Self.categoriesImporting.insert(category.id)
        importingSamplers = true
        Task { @MainActor in
            let failures = await Task.detached(priority: .utility) {
                urls.compactMap { source in
                    do { try Self.copySampler(source, into: directory); return nil as String? }
                    catch { return "\(source.lastPathComponent) — \(error.localizedDescription)" }
                }
            }.value
            Self.categoriesImporting.remove(category.id)
            importingSamplers = false
            if selection == .samplerCategory(category.id) {
                loadSamplers()
                samplerError = failures.joined(separator: "\n")
            }
        }
    }

    @discardableResult nonisolated static func copySampler(_ source: URL, into directory: URL, forPad: Bool = false) throws -> URL {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent("." + UUID().uuidString).appendingPathExtension(source.pathExtension)
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: source, to: temporary)
        let audio = try AVAudioFile(forReading: temporary)
        let rate = audio.fileFormat.sampleRate
        guard audio.length > 0, rate.isFinite, rate > 0 else { throw CocoaError(.fileReadCorruptFile) }
        if forPad, !VinhetasPad.acceptsDuration(frames: audio.length, sampleRate: rate) {
            throw ProjectError.invalid(JarasLocalization.string("Pads accept audio up to 60 seconds."))
        }
        let base = source.deletingPathExtension().lastPathComponent
        var target = directory.appendingPathComponent(source.lastPathComponent)
        var copyNumber = 2
        while true {
            do {
                try manager.moveItem(at: temporary, to: target)
                return target
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                if forPad && manager.contentsEqual(atPath: temporary.path, andPath: target.path) { return target }
            }
            target = directory.appendingPathComponent("\(base) \(copyNumber)").appendingPathExtension(source.pathExtension)
            copyNumber += 1
        }
    }

    private func togglePreview(_ url: URL, instrumentID: String? = nil) {
        let wasPlaying = preview?.url == url
        stopPreview()
        guard !wasPlaying else { return }
        let id = UUID()
        preview = (id, url, instrumentID)
        if instrumentID != nil { instruments.error = "" }
        else { samplerError = "" }
        let playback = projectAudio
        previewPreparation = Task { @MainActor in
            defer { if preview?.id == id { previewPreparation = nil } }
            do {
                let finished: @MainActor () -> Void = {
                    if preview?.id == id { preview = nil }
                }
                if let instrumentID {
                    let drums = InstrumentLibrary.category(instrumentID) == .drum
                    let buffer = try await LibrarySoundFontPreviewRenderer.shared.render(url, drums: drums)
                    guard !Task.isCancelled, preview?.id == id else { return }
                    try playback.playLibrarySampler(id, buffer: buffer, gain: 1, finished: finished)
                } else {
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try StemAudioPlayback.PreparedLibrarySampler.open(url)
                    }.value
                    guard !Task.isCancelled, preview?.id == id else { return }
                    try playback.playLibrarySampler(id, prepared: prepared, gain: samplerPreviewGain, finished: finished)
                }
            } catch {
                if preview?.id == id {
                    if instrumentID != nil { instruments.error = error.localizedDescription }
                    else { samplerError = error.localizedDescription }
                    preview = nil
                }
            }
        }
    }

    private var samplerPreviewGain: Float {
        samplerPreviewDB <= -60 ? 0 : Float(pow(10, min(0, samplerPreviewDB) / 20))
    }

    private var projectAudio: StemAudioPlayback {
        #if os(macOS)
        DesktopProjectTabs.shared.audio(for: show)
        #else
        StemAudioPlayback.shared
        #endif
    }

    private func stopPreview() {
        previewPreparation?.cancel()
        previewPreparation = nil
        guard let id = preview?.id else { return }
        preview = nil
        projectAudio.stopPad(id)
    }


}

@MainActor enum LibraryEffectInsertion {
    static func apply(identity: String, presetID: String?, to track: UUID?, clip: UUID? = nil,
                      before target: String? = nil, show: ShowController) -> String? {
        guard !ProjectSyncControl.following,
              track == nil || show.current?.tracks.contains(where: { $0.id == track && $0.kind == .standard }) == true,
              clip == nil || FXModelLookup.clip(clip!, in: show.snapshot.project) != nil else { return nil }
        let original = clip.map(show.clipFXSettings) ?? show.fxSettings(track)
        guard target == nil || original.inserted.contains(target!) else { return nil }
        var settings = original
        do {
            let key: String
            if identity.hasPrefix("native:") {
                let parts = identity.dropFirst(7).split(separator: ":", maxSplits: 1)
                guard let rawKind = parts.first else { return nil }
                let kind = String(rawKind)
                if kind == NativeFXSettings.waveLFOName {
                    if let clip {
                        guard let owner = show.current?.tracks.first(where: { $0.clips.contains { $0.id == clip } }),
                              owner.kind == .standard, let item = owner.clips.first(where: { $0.id == clip }),
                              !item.isImage, item.midi == nil, (item.audioFile ?? owner.audioFile) != nil else { return nil }
                    } else if track == nil { return nil }
                    if original.inserted.contains(kind), presetID == nil { return kind }
                } else if !NativeFXSettings.order.contains(kind) { return nil }
                if kind == "Instruments" {
                    guard parts.count == 2, !isVinhetas(track, show: show) else { return nil }
                    let instrument = String(parts[1])
                    guard InstrumentLibrary.shared.downloaded.contains(instrument) else {
                        throw ProjectError.invalid("Download the instrument before inserting its preset")
                    }
                    key = settings.appendNative(kind, instrument: instrument, parameters: InstrumentLibrary.parameters(instrument),
                                                asInstance: clip != nil)
                } else {
                    key = settings.appendNative(kind, asInstance: clip != nil && !original.effectKeys.isEmpty)
                }
            } else {
                #if os(macOS)
                let classID = String(identity.dropFirst(5))
                guard identity.hasPrefix("vst3:"),
                      let descriptor = PluginCatalog.shared.plugins.first(where: { $0.classID.caseInsensitiveCompare(classID) == .orderedSame }),
                      !descriptor.isInstrument || !isVinhetas(track, show: show) else { return nil }
                let instance = descriptor.instance
                settings.externalPlugins = (settings.externalPlugins ?? []) + [instance]
                key = instance.effectKey
                settings.inserted.append(key)
                #else
                return nil
                #endif
            }
            guard !original.inserted.contains(key) || key == NativeFXSettings.waveLFOName else { return nil }
            let library = try FXPresetStore.shared.read()
            if let presetID {
                guard let preset = library.presets.first(where: { $0.id == presetID }) else { throw ProjectError.invalid("Preset not found for this plugin") }
                settings = try preset.applying(to: settings, effect: key)
            } else {
                settings = try library.applyingDefault(to: settings, effect: key)
            }
            if key != NativeFXSettings.waveLFOName, let target, let index = original.inserted.firstIndex(of: target) {
                settings.inserted.removeAll { $0 == key }
                settings.inserted.insert(key, at: index)
            }
            try settings.validate()
            #if os(macOS)
            if let plugin = settings.externalPlugins?.first(where: { $0.effectKey == key }) {
                if let chain = DesktopProjectTabs.shared.audio(for: show).effects(for: clip ?? track) {
                    do { _ = try chain.prepareExternal(plugin) }
                    catch { chain.apply(original); throw error }
                } else if clip != nil {
                    let chain = NativeEffectsChain()
                    defer { chain.releaseExternal() }
                    _ = try chain.prepareExternal(plugin)
                }
            }
            #endif
            if let clip { show.previewClipFX(clip, settings: settings) }
            else { show.previewFX(track, settings: settings) }
            show.commitFX()
            let applied = clip.map(show.clipFXSettings) ?? show.fxSettings(track)
            if applied.inserted.contains(key) { show.onProjectEdited(); return key }
            return nil
        } catch {
            show.message = error.localizedDescription
            return nil
        }
    }
    private static func isVinhetas(_ track: UUID?, show: ShowController) -> Bool {
        show.current?.tracks.first(where: { $0.id == track })?.role.rawValue == "vinhetas"
    }
}


@MainActor private struct LibraryTimelineList: View {
    private struct Entry: Identifiable, Equatable {
        let id: UUID
        let name: String
        let label: String
        let position: Double
    }

    let show: ShowController
    let regions: Bool
    let docked: Bool
    @State private var keyboardTarget = LibraryKeyboardTarget()
    #if os(macOS)
    @State private var scrollController = SidebarScrollController()
    #endif
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @ObservedObject private var selection: LibraryTimelineSelection
    @State private var entries: [Entry] = []
    @State private var songID: UUID?
    @State private var editing: UUID?
    private final class RenameDraft {
        var original = ""
        var text = ""
    }
    // AppKit and UIKit maintain the field editor. Typing does not invalidate the list.
    @State private var draft = RenameDraft()
    private var nameBinding: Binding<String> {
        Binding(get: { draft.text }, set: { draft.text = $0 })
    }

    init(show: ShowController, regions: Bool, docked: Bool) {
        self.show = show; self.regions = regions; self.docked = docked
        selection = show.libraryTimelineSelection
    }

    private var selected: UUID? { selection.state.selected(in: songID, region: regions) }

    private func refreshEntries() {
        let song = show.current
        if songID != song?.id {
            songID = song?.id; editing = nil
        }
        guard let song else { entries = []; return }
        let values: [Entry]
        if regions {
            values = song.parts.map { Entry(id: $0.id, name: $0.name, label: $0.displayName, position: $0.startTime) }
        } else {
            let parts = Dictionary(uniqueKeysWithValues: song.parts.map { ($0.id, $0) })
            values = (song.markers ?? []).filter(\.isNavigationMarker).map { marker in
                let source = marker.sourceRegionID.flatMap { parts[$0] }
                return Entry(id: marker.id, name: source?.name ?? marker.name,
                             label: source?.displayName ?? marker.name, position: marker.position)
            }
        }
        let sorted = values.sorted { $0.position < $1.position }
        if sorted != entries { entries = sorted }
        if let editing, !entries.contains(where: { $0.id == editing }) { self.editing = nil }
    }

    var body: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = query.isEmpty ? entries : entries.filter { $0.label.localizedStandardContains(query) || $0.id == editing }
        VStack(spacing: 0) {
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain).font(.jarasSystem(size: 12))
                .padding(.horizontal, 7).frame(height: 24)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                .padding(.horizontal, 6).padding(.vertical, 4)
                .focused($searchFocused)
                .accessibilityIdentifier("library-timeline-search")
            timelineRows(rows)
        }
        .background {
            LibraryKeyboardArea(capturesTab: true, preferredTab: docked, keyboardTarget: keyboardTarget,
                                arrowReleased: { show.finishLibraryTimelineNavigation(region: regions) }) { code in
                switch code {
                case 48: searchFocused = true; return true
                case 125, 126: return step(code == 125 ? 1 : -1, in: rows)
                default: return false
                }
            }
        }
        .onAppear(perform: refreshEntries)
        .onReceive(show.projectPresentation.objectWillChange) { refreshEntries() }
        .onChange(of: regions) { _ in editing = nil; refreshEntries() }
        .onReceive(selection.$state) { state in
            if let editing, let selected = state.selected(in: songID, region: regions), selected != editing {
                finish(editing)
            }
        }
    }

    private static let rowHeight: CGFloat = 25
    private static let rowSpacing: CGFloat = 2
    private static let rowPadding: CGFloat = 6

    private func timelineRows(_ rows: [Entry]) -> some View {
        ScrollViewReader { scroll in
            LibraryScrollView {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        Group {
                            if editing == row.id {
                                nameInput(for: row, rows: rows)
                            } else {
                                RowLabel(entry: row, controller: ObjectIdentifier(show), selected: selected == row.id,
                                    select: { select(row) }, rename: { begin(row) }).equatable()
                            }
                        }
                        .frame(height: Self.rowHeight)
                        .background(selected == row.id ? JarasTheme.green.opacity(0.24) : Color.white.opacity(index.isMultiple(of: 2) ? 0.045 : 0),
                                    in: RoundedRectangle(cornerRadius: 4))
                        .id(row.id)
                    }
                }.padding(Self.rowPadding)
                #if os(macOS)
                .background(SidebarScrollProbe(controller: scrollController))
                #endif
            }
            .onChange(of: editing ?? selected) { id in
                guard let id, let index = rows.firstIndex(where: { $0.id == id }) else { return }
                #if os(macOS)
                // ScrollViewReader forces the lazy list to resolve the target
                // even when it is already on screen. Only reveal clipped rows.
                let top = Self.rowPadding + CGFloat(index) * (Self.rowHeight + Self.rowSpacing)
                let viewport = scrollController.metrics
                if viewport.viewportHeight > 0, top >= viewport.offset - 0.5,
                   top + Self.rowHeight <= viewport.offset + viewport.viewportHeight + 0.5 { return }
                #endif
                scroll.scrollTo(id)
            }
        }
    }

    private func step(_ direction: Int, in rows: [Entry]) -> Bool {
        guard !rows.isEmpty else { return true }
        let index = rows.firstIndex { $0.id == (editing ?? selected) }
        let nextIndex = index.map { $0 + direction } ?? (direction > 0 ? 0 : rows.count - 1)
        guard rows.indices.contains(nextIndex) else { return true }
        let next = rows[nextIndex]
        if let editing {
            commitDraft(editing)
            draft.original = next.name; draft.text = next.name; self.editing = next.id
        }
        show.browseLibraryTimelineEntry(next.id, region: regions, commitAfterDelay: !keyboardTarget.holdingArrow)
        return true
    }

    private struct RowLabel: View, Equatable {
        let entry: Entry
        let controller: ObjectIdentifier
        let selected: Bool
        let select: () -> Void
        let rename: () -> Void

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.entry == rhs.entry && lhs.controller == rhs.controller && lhs.selected == rhs.selected
        }

        var body: some View {
            let label = Text(verbatim: entry.label).font(.jarasSystem(size: 12))
                .lineLimit(1).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 6).contentShape(Rectangle())
            return Group {
                #if os(macOS)
                label.onTapGesture(perform: select)
                    .immediateRightClick { DispatchQueue.main.async { rename() } }
                #else
                label.overlay { IpadTapHoldTouchSurface(tap: select, hold: rename) }
                #endif
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: entry.label))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select() }
            .accessibilityAction(named: Text("Rename")) { rename() }
        }
    }

    private func select(_ row: Entry) {
        if let editing {
            guard editing != row.id else { return }
            finish(editing)
        }
        LibraryKeyboardTarget.active = keyboardTarget
        #if os(macOS)
        keyboardTarget.focus()
        #else
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
        show.clickLibraryTimelineEntry(row.id, region: regions)
    }

    private func begin(_ row: Entry) {
        if let editing, editing != row.id { finish(editing) }
        guard show.canControl() else { return }
        draft.original = row.name; draft.text = row.name; editing = row.id
    }

    private func finish(_ id: UUID, save: Bool = true) {
        guard editing == id else { return }
        editing = nil
        if save { commitDraft(id) }
    }

    private func commitDraft(_ id: UUID) {
        if draft.text != draft.original { show.renameTimelineLabel(id, name: draft.text, region: regions, includesUnified: true) }
    }

    private func nameInput(for row: Entry, rows: [Entry]) -> some View {
        let move: (Int) -> Void = { direction in
            guard editing == row.id else { return }
            _ = step(direction, in: rows)
        }
        #if os(macOS)
        return LibraryTimelineNameInput(text: nameBinding, keyboardTarget: keyboardTarget, finish: { finish(row.id, save: $0) }, move: move)
        #else
        return InlineNameInput(text: nameBinding, compact: false, finish: { finish(row.id) }, move: move,
                        accessibilityName: regions ? "Region name" : "Marker name")
        #endif
    }
}

private actor LibraryMIDIStorage {
    static let shared = LibraryMIDIStorage()

    private func directory(_ id: UUID) throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("JarasLive/MIDI", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    nonisolated static func read(_ url: URL, checkExtension: Bool = true) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL, !checkExtension || ["mid", "midi"].contains(url.pathExtension.lowercased()),
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, (1...64 * 1024 * 1024).contains(size) else {
            throw ProjectError.invalid("Invalid MIDI file.")
        }
        return try Data(contentsOf: url)
    }

    func files(in id: UUID) -> [URL] {
        guard let directory = try? directory(id),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return [] }
        return files.filter { ["mid", "midi"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func saveFile(_ data: Data, named name: String, into id: UUID) throws {
        _ = try StandardMIDIFileImport.read(data)
        try save(data, named: name, into: id)
    }

    func copy(_ urls: [URL], into id: UUID) -> [String] {
        urls.compactMap { url in
            do { try saveFile(Self.read(url), named: url.deletingPathExtension().lastPathComponent, into: id); return nil }
            catch { return "\(url.lastPathComponent) — \(error.localizedDescription)" }
        }
    }

    func export(_ clips: [AudioClip], into id: UUID) -> [String] {
        clips.compactMap { clip in
            do { try save(MIDIItemExport.data(for: clip), named: clip.name, into: id); return nil }
            catch { return "\(clip.name) — \(error.localizedDescription)" }
        }
    }

    private func save(_ data: Data, named name: String, into id: UUID) throws {
        let directory = try directory(id)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = String(name.components(separatedBy: CharacterSet(charactersIn: "/:").union(.controlCharacters))
            .joined(separator: "-").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))).prefix(60))
        let base = stem.isEmpty ? "MIDI" : stem
        var version = 1
        while true {
            let filename = version == 1 ? base : "\(base) (\(version))"
            let url = directory.appendingPathComponent(filename).appendingPathExtension("mid")
            if !manager.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic); return }
            version += 1
        }
    }
}

@MainActor final class LibraryKeyboardTarget {
    static let registered = NSHashTable<LibraryKeyboardTarget>.weakObjects()
    static weak var active: LibraryKeyboardTarget?
    var acceptsPointer: (CGPoint) -> Bool = { _ in false }
    var isVisible: () -> Bool = { false }
    var capturesTab = false
    var preferredTab = false
    var handle: (Int) -> Bool = { _ in false }
    var holdingArrow = false
    var arrowReleased: (() -> Void)?
    #if os(macOS)
    var focus: () -> Void = {}
    #else
    private static weak var hardwareArrowTarget: LibraryKeyboardTarget?
    private static var hardwareArrowKey: Int?

    static func handleHardwareArrow(_ event: HardwareKeyboardEvent) -> Bool {
        let code = Int(event.keyCode)
        if event.phase == .up {
            guard hardwareArrowKey == code else { return false }
            finishHardwareArrow(commit: true)
            return true
        }
        guard event.modifiers.isEmpty, code == 125 || code == 126,
              let target = active, target.isVisible(), target.arrowReleased != nil else { return false }
        if !event.isRepeat {
            finishHardwareArrow(commit: false)
            hardwareArrowTarget = target
            hardwareArrowKey = code
            target.holdingArrow = true
        }
        guard hardwareArrowKey == code, hardwareArrowTarget === target else { return true }
        return target.handle(code)
    }

    static func finishHardwareArrow(commit: Bool) {
        let target = hardwareArrowTarget
        hardwareArrowTarget = nil
        hardwareArrowKey = nil
        target?.holdingArrow = false
        if commit, target?.isVisible() == true { target?.arrowReleased?() }
    }
    #endif

    init() { Self.registered.add(self) }

    static func pointer(at point: CGPoint) {
        #if os(iOS)
        finishHardwareArrow(commit: false)
        #endif
        active = registered.allObjects.first { $0.isVisible() && $0.acceptsPointer(point) }
    }

    static func dispatch(_ code: Int) -> Bool {
        if code == 48 {
            let visible = registered.allObjects.filter { $0.capturesTab && $0.isVisible() }
            return (visible.first { $0.preferredTab } ?? visible.first)?.handle(code) ?? false
        }
        guard let active, active.isVisible() else { return false }
        return active.handle(code)
    }
}

#if os(iOS)
private struct LibraryKeyboardArea: UIViewRepresentable {
    var capturesTab = false
    var preferredTab = false
    var keyboardTarget: LibraryKeyboardTarget? = nil
    var arrowReleased: (() -> Void)? = nil
    let action: (Int) -> Bool

    final class InputView: UIView {
        let target = LibraryKeyboardTarget()
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
    }
    func makeUIView(context: Context) -> InputView { InputView() }
    func updateUIView(_ view: InputView, context: Context) {
        let target = keyboardTarget ?? view.target
        target.handle = action
        target.arrowReleased = arrowReleased
        target.capturesTab = capturesTab; target.preferredTab = preferredTab
        target.isVisible = { [weak view] in
            guard let view else { return false }
            return view.window?.isKeyWindow == true && !view.isHidden && !view.bounds.isEmpty
        }
        target.acceptsPointer = { [weak view] point in
            guard let view, let window = view.window else { return false }
            return view.bounds.contains(view.convert(point, from: window))
        }
    }
}
#else
struct LibraryKeyboardArea: NSViewRepresentable {
    var capturesTab = false
    var preferredTab = false
    var keyboardTarget: LibraryKeyboardTarget? = nil
    var arrowReleased: (() -> Void)? = nil
    let action: (Int) -> Bool

    final class InputView: NSView {
        let target = LibraryKeyboardTarget()
        var commandTarget: LibraryKeyboardTarget?
        static var monitor: Any?
        static weak var arrowTarget: LibraryKeyboardTarget?
        static weak var arrowWindow: NSWindow?
        static var arrowKey: UInt16?
        static var arrowTimer: Timer?

        static func stopArrow(commit: Bool) {
            let target = arrowTarget
            arrowTimer?.invalidate()
            arrowTimer = nil; arrowKey = nil; arrowTarget = nil; arrowWindow = nil
            target?.holdingArrow = false
            if commit, target?.isVisible() == true { target?.arrowReleased?() }
        }

        static func beginArrow(_ event: NSEvent, target: LibraryKeyboardTarget) -> Bool {
            let code = event.keyCode
            guard target.arrowReleased != nil, code == 125 || code == 126 else { return target.handle(Int(code)) }
            if event.isARepeat || arrowKey == code { return true }
            stopArrow(commit: false)
            arrowTarget = target; arrowWindow = event.window; arrowKey = code
            target.holdingArrow = true
            guard target.handle(Int(code)) else { stopArrow(commit: false); return false }
            let timer = Timer(fire: Date(timeIntervalSinceNow: 0.20), interval: 0.055, repeats: true) { [weak target] _ in
                MainActor.assumeIsolated {
                    guard let target, target.isVisible(), arrowWindow?.attachedSheet == nil,
                          NSApp.modalWindow == nil, target.handle(Int(code)) else {
                        stopArrow(commit: false)
                        return
                    }
                }
            }
            timer.tolerance = 0.004
            arrowTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            return true
        }

        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if !LibraryKeyboardArea.handle(event) { super.keyDown(with: event) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, Self.monitor == nil else { return }
            Self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .keyUp, .flagsChanged]) { event in
                switch event.type {
                case .keyUp:
                    guard event.keyCode == Self.arrowKey else { return event }
                    Self.stopArrow(commit: event.window != nil && event.window === Self.arrowWindow && event.window?.isKeyWindow == true)
                    return nil
                case .flagsChanged:
                    if !event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty {
                        Self.stopArrow(commit: false)
                    }
                    return event
                case .leftMouseDown, .rightMouseDown:
                    Self.stopArrow(commit: false)
                    LibraryKeyboardTarget.pointer(at: event.locationInWindow)
                    if let window = event.window, let previous = window.firstResponder as? InputView,
                       previous.commandTarget !== LibraryKeyboardTarget.active {
                        window.makeFirstResponder(nil)
                    }
                    return event
                case .keyDown:
                    return LibraryKeyboardArea.handle(event) ? nil : event
                default:
                    return event
                }
            }
        }
    }
    static func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let window = event.window, window.isKeyWindow,
              window.attachedSheet == nil, window.sheetParent == nil, NSApp.modalWindow == nil,
              ControlMappings.shared.editing == nil, !NativeTimelineInputGate.shared.isBlocked(window),
              !(window.firstResponder is NSTextField), !(window.firstResponder is NSTextView) else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if flags.isEmpty, event.keyCode == 48 { return LibraryKeyboardTarget.dispatch(48) }
        if flags.isEmpty, event.keyCode == 125 || event.keyCode == 126 {
            let target = (window.firstResponder as? InputView)?.commandTarget ?? LibraryKeyboardTarget.active
            guard let target, target.isVisible() else { return false }
            return InputView.beginArrow(event, target: target)
        }
        if (flags == .command || flags == .control), event.keyCode == 9 {
            return LibraryKeyboardTarget.dispatch(9)
        }
        return false
    }
    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        let target = keyboardTarget ?? view.target
        view.commandTarget = target
        target.handle = action
        target.arrowReleased = arrowReleased
        target.focus = { [weak view] in
            if let view { view.window?.makeFirstResponder(view) }
        }
        target.capturesTab = capturesTab; target.preferredTab = preferredTab
        target.isVisible = { [weak view] in
            guard let view else { return false }
            return view.window?.isKeyWindow == true && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty
        }
        target.acceptsPointer = { [weak view] point in
            guard let view else { return false }
            return view.visibleRect.contains(view.convert(point, from: nil))
        }
    }
}

private struct LibraryTimelineNameInput: NSViewRepresentable {
    @Binding var text: String
    let keyboardTarget: LibraryKeyboardTarget
    let finish: (Bool) -> Void
    let move: (Int) -> Void

    final class Field: NSTextField, NSTextFieldDelegate {
        var input: LibraryTimelineNameInput?
        private var outsideClick: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            outsideClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if let self, event.window == self.window,
                   !self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.input?.finish(true)
                }
                return event
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, window.makeFirstResponder(self) else { return }
                self.selectText(nil)
            }
        }

        func stopWatching() {
            if let outsideClick { NSEvent.removeMonitor(outsideClick); self.outsideClick = nil }
        }
        func controlTextDidChange(_ notification: Notification) { input?.text = stringValue }
        // Only an explicit outside click, Return or Escape closes this row.
        // AppKit also sends end-editing notifications when moving the shared
        // field editor between rows during keyboard navigation.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)): input?.finish(true)
            case #selector(NSResponder.cancelOperation(_:)): input?.finish(false)
            case #selector(NSResponder.moveUp(_:)): return move(-1)
            case #selector(NSResponder.moveDown(_:)): return move(1)
            default: return false
            }
            return true
        }

        private func move(_ direction: Int) -> Bool {
            guard let input else { return false }
            if let event = NSApp.currentEvent, event.type == .keyDown,
               event.window === window, event.keyCode == (direction < 0 ? 126 : 125),
               event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty {
                return LibraryKeyboardArea.InputView.beginArrow(event, target: input.keyboardTarget)
            }
            input.move(direction)
            return true
        }
    }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.stringValue = text; field.delegate = field
        field.isEditable = true; field.isSelectable = true
        field.setAccessibilityLabel(JarasLocalization.string("Rename"))
        field.font = .jarasSystemFont(ofSize: 12)
        field.textColor = .white; field.backgroundColor = NSColor(white: 0.10, alpha: 1)
        field.isBezeled = true; field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: Field, context: Context) { field.input = self }
    static func dismantleNSView(_ field: Field, coordinator: ()) {
        field.input = nil; field.delegate = nil; field.stopWatching()
    }
}
#endif
