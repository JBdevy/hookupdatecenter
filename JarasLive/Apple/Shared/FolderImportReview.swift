import SwiftUI

#if os(iOS)
struct NativeStemImportReview: View {
    @ObservedObject var documents: ProjectDocuments
    let scan: StemScan
    @State private var askingForBPM = false
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case name, cleanup }
    private var count: Int { scan.folders.reduce(0) { $0 + $1.files.count } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "waveform").font(.jarasTitle2).foregroundStyle(JarasTheme.green)
                Text("Review stems").font(.jarasTitle3.bold())
                Spacer()
                Text("\(scan.folders.count) songs").font(.jarasSubheadline.bold()).foregroundStyle(JarasTheme.green)
                Text("\(count) audio files").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
            }
            ScrollViewReader { scroll in
                ScrollView {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Import order", systemImage: "list.number").font(.jarasHeadline)
                            ForEach(Array(scan.folders.enumerated()), id: \.element.url) { entry in
                                HStack(spacing: 10) {
                                    Text(String(format: "%02d", entry.offset + 1)).monospacedDigit().foregroundStyle(JarasTheme.green)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.element.url.lastPathComponent).font(.jarasBody.weight(.semibold)).lineLimit(2)
                                        Text("\(entry.element.files.count) audio files").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(10).background(JarasTheme.display, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .topLeading).background(importPanel, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 12) {
                            if !documents.adding {
                                Text("Project name").font(.jarasSubheadline.bold())
                                TextField("Project name", text: $documents.nativeProjectName).textFieldStyle(.roundedBorder)
                                    .focused($focusedField, equals: .name).id(Field.name)
                            }
                            Label("Track names", systemImage: "textformat").font(.jarasHeadline)
                            TextField("Names to remove, separated by commas", text: $documents.removal)
                                .textFieldStyle(.roundedBorder).focused($focusedField, equals: .cleanup).id(Field.cleanup)
                            Text("Remove repeated words from track names, if needed. Original files remain unchanged.")
                                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                            ForEach(scan.suggestions) { item in
                                Button { toggle(item.text) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: terms.contains(item.text) ? "checkmark.square.fill" : "square").foregroundStyle(JarasTheme.green)
                                        Text(item.text).lineLimit(2)
                                        Spacer(minLength: 4)
                                        Text("\(item.count)×").font(.jarasCaption.monospacedDigit()).foregroundStyle(JarasTheme.secondary)
                                    }.padding(10).frame(maxWidth: .infinity, minHeight: 40).contentShape(Rectangle())
                                        .background(JarasTheme.display, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                            ForEach(Array(documents.warnings.enumerated()), id: \.offset) { entry in
                                Text(verbatim: entry.element).font(.jarasCaption).foregroundStyle(JarasTheme.yellow)
                            }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .topLeading).background(importPanel, in: RoundedRectangle(cornerRadius: 10))
                    }
                }.scrollDismissesKeyboard(.interactively)
                    .onChange(of: focusedField) { field in
                        if let field { withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo(field, anchor: .top) } }
                    }
            }
            HStack(spacing: 10) {
                Button("Back") { dismissKeyboard(); documents.reviewFolderOrder() }
                Button("Cancel") { dismissKeyboard(); documents.cancelImport() }
                Spacer()
                Button {
                    dismissKeyboard()
                    if !documents.adding && documents.nativeProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        focusedField = .name
                    } else { askingForBPM = true }
                } label: {
                    Label(LocalizedStringKey(documents.adding ? "Add to project" : "Create Project"), systemImage: "checkmark")
                        .frame(minHeight: 36).contentShape(Rectangle())
                }.buttonStyle(StageButtonStyle(color: JarasTheme.green, active: true))
                    .accessibilityIdentifier("native-stems-confirm")
            }.buttonStyle(IpadDialogButtonStyle()).fixedSize(horizontal: false, vertical: true)
        }.background(RemoteKeyboardDismissal(active: focusedField != nil, dismiss: dismissKeyboard))
            .alert("Detect BPM for each song?", isPresented: $askingForBPM) {
                Button("Yes") { documents.confirmNativeStemImport(detectBPM: true) }
                Button("No") { documents.confirmNativeStemImport(detectBPM: false) }
                Button("Cancel", role: .cancel) {}
            }
    }
    private func dismissKeyboard() {
        focusedField = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    private var importPanel: LinearGradient {
        LinearGradient(colors: [Color(white: 0.19), Color(white: 0.13)], startPoint: .top, endPoint: .bottom)
    }
    private var terms: [String] { documents.removal.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    private func toggle(_ text: String) {
        var names = terms
        if let index = names.firstIndex(of: text) { names.remove(at: index) } else { names.append(text) }
        documents.removal = names.joined(separator: ", ")
    }
}

/// The system picker grants access to a parent directory; selection and order
/// remain inside CatLive, independently of a Files provider's selection UI.
struct NativeStemFolderBrowser: View {
    let root: URL
    let cancel: () -> Void
    let confirm: ([URL]) -> Void
    @State private var current: URL
    @State private var children: [URL] = []
    @State private var audioCounts: [URL: Int] = [:]
    @State private var selected: [URL] = []
    @State private var loading = true
    @State private var failure = ""
    @State private var refresh = UUID()

    init(root: URL, cancel: @escaping () -> Void, confirm: @escaping ([URL]) -> Void) {
        self.root = root; self.cancel = cancel; self.confirm = confirm
        _current = State(initialValue: root)
    }
    static func contains(_ url: URL, in root: URL) -> Bool {
        let parent = root.standardizedFileURL.resolvingSymlinksInPath().path
        let child = url.standardizedFileURL.resolvingSymlinksInPath().path
        return child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose folders").font(.jarasTitle3.bold())
            Text("Open the folder containing your songs, check the folders you want, then continue.")
                .font(.jarasCallout).foregroundStyle(JarasTheme.secondary)
            HStack {
                Button { navigate(current.deletingLastPathComponent()) } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(current.standardizedFileURL == root.standardizedFileURL)
                Text(current.lastPathComponent).font(.jarasHeadline).lineLimit(1)
                Spacer()
                Button("Select all") { for folder in children where (audioCounts[folder] ?? 0) > 0 && !selected.contains(folder) { selected.append(folder) } }
                    .disabled(loading || children.isEmpty)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 8) {
                    folderRow(current, currentFolder: true)
                    if loading { ProgressView().padding() }
                    if !failure.isEmpty {
                        Text(verbatim: failure).foregroundStyle(.red)
                        Button("Retry") { refresh = UUID() }
                    }
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(children, id: \.self) { folderRow($0, currentFolder: false) }
                        }
                    }
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    Text("All regions preview").font(.jarasHeadline)
                    Text("Folders will be placed on the grid in the order you check them.")
                        .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(selected.enumerated()), id: \.element) { entry in
                                HStack {
                                    Text(String(format: "%02d", entry.offset + 1)).monospacedDigit().foregroundStyle(JarasTheme.green)
                                    Text(entry.element.lastPathComponent).lineLimit(2)
                                    Spacer(minLength: 0)
                                    Button { toggle(entry.element) } label: { Image(systemName: "xmark.circle") .frame(width: 44, height: 44) }
                                        .accessibilityLabel("Remove")
                                }.padding(.leading, 8).background(JarasTheme.panel, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }.frame(maxWidth: .infinity)
            }.frame(maxHeight: .infinity)
            HStack {
                Button("Cancel", action: cancel)
                Spacer()
                Text("\(selected.count)").monospacedDigit().foregroundStyle(JarasTheme.green)
                Button("Continue") { confirm(selected) }
                    .buttonStyle(StageButtonStyle(color: JarasTheme.green)).disabled(selected.isEmpty || loading)
            }
        }.task(id: refresh) { await load() }
    }
    private func folderRow(_ folder: URL, currentFolder: Bool) -> some View {
        HStack(spacing: 0) {
            Button { toggle(folder) } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected.contains(folder) ? "checkmark.square.fill" : "square").foregroundStyle(JarasTheme.green)
                    VStack(alignment: .leading) {
                        Text(folder.lastPathComponent).lineLimit(2)
                        if let count = audioCounts[folder] {
                            if count > 0 { Text("\(count) audio files").font(.jarasCaption).foregroundStyle(JarasTheme.secondary) }
                            else { Text("No audio directly in this folder").font(.jarasCaption).foregroundStyle(JarasTheme.secondary) }
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(12).frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled((audioCounts[folder] ?? 0) == 0)
                .opacity((audioCounts[folder] ?? 0) == 0 ? 0.5 : 1)
            if !currentFolder {
                Button { navigate(folder) } label: { Image(systemName: "chevron.right").frame(width: 48, height: 48).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel(Text("Open folder") + Text(" ") + Text(folder.lastPathComponent))
            }
        }.background(JarasTheme.panel, in: RoundedRectangle(cornerRadius: 8))
    }
    private func toggle(_ folder: URL) {
        guard (audioCounts[folder] ?? 0) > 0 || selected.contains(folder) else { return }
        if let index = selected.firstIndex(of: folder) { selected.remove(at: index) }
        else { selected.append(folder) }
    }
    private func navigate(_ url: URL) {
        guard Self.contains(url, in: root) else { return }
        current = url; children = []; loading = true; failure = ""; refresh = UUID()
    }
    private func load() async {
        let directory = current, root = root, request = refresh
        loading = true; failure = ""
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let scoped = root.startAccessingSecurityScopedResource()
                defer { if scoped { root.stopAccessingSecurityScopedResource() } }
                var coordinationError: NSError?
                var result: Result<[URL], Error> = .success([])
                NSFileCoordinator().coordinate(readingItemAt: directory, options: [], error: &coordinationError) { url in
                    result = Result {
                        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                            .filter {
                                let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
                                return values.isDirectory == true && values.isPackage != true && values.isSymbolicLink != true && Self.contains($0, in: root)
                            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    }
                }
                if let coordinationError { throw coordinationError }
                let folders = try result.get()
                var counts: [URL: Int] = [:]
                for folder in [directory] + folders {
                    let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                    counts[folder] = try entries.filter {
                        guard ["wav", "wave", "aif", "aiff", "mp3"].contains($0.pathExtension.lowercased()) else { return false }
                        return try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true
                    }.count
                }
                return (folders, counts)
            }.value
            guard !Task.isCancelled, request == refresh else { return }
            children = result.0; audioCounts.merge(result.1) { _, new in new }; loading = false
        } catch {
            guard !Task.isCancelled, request == refresh else { return }
            failure = error.localizedDescription; loading = false
        }
    }
}
#endif

struct FolderImportReview: View {
    @State private var selection: FolderImportSelection
    @State private var query = ""
    let appending: Bool
    let cancel: () -> Void
    let confirm: ([URL]) -> Void

    init(folders: [URL], selectedFolders: [URL] = [], appending: Bool = false,
         cancel: @escaping () -> Void, confirm: @escaping ([URL]) -> Void) {
        var selection = FolderImportSelection(folders)
        for folder in selectedFolders where selection.position(of: folder) == nil { selection.toggle(folder) }
        _selection = State(initialValue: selection)
        self.appending = appending
        self.cancel = cancel; self.confirm = confirm
    }
    private var rowHeight: CGFloat {
        #if os(iOS)
        return 48
        #else
        return 34
        #endif
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Choose folders", systemImage: "folder.badge.plus").font(.jarasTitle2.bold()).foregroundStyle(JarasTheme.green)
            HStack {
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(JarasTheme.secondary)
                    TextField("Search folders", text: $query).textFieldStyle(.plain)
                }.padding(9).frame(maxWidth: 310).background(JarasTheme.panel, in: RoundedRectangle(cornerRadius: 6))
                Spacer(minLength: 0)
            }
            HStack {
                Button(selection.allSelected ? "Deselect all" : "Select all") { selection.toggleAll() }
                Spacer()
                Text("\(selection.selected.count) / \(selection.folders.count)").font(.jarasCaption.monospacedDigit()).foregroundStyle(JarasTheme.secondary)
            }
            Text(LocalizedStringKey(appending
                ? "Songs will be added in this order after the last song in the open project."
                : "Folders will be placed on the grid in the order you check them."))
                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Folders").font(.jarasCaption.bold()).foregroundStyle(JarasTheme.secondary)
                    ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(selection.matching(query), id: \.self) { folder in
                        let order = selection.position(of: folder)
                        Button { selection.toggle(folder) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: order == nil ? "square" : "checkmark.square.fill")
                                    .foregroundStyle(order == nil ? JarasTheme.secondary : JarasTheme.green)
                                    .font(.jarasSystem(size: 16)).frame(width: 20)
                                Text(folder.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                if let order { Text(String(format: "%02d", order)).font(.jarasCaption.monospacedDigit().bold()).foregroundStyle(JarasTheme.green) }
                            }.padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: rowHeight)
                                .background(order == nil ? JarasTheme.panel : JarasTheme.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(folder.lastPathComponent)
                            .accessibilityValue(order.map { String($0) } ?? "Not selected")
                            .jarasHelp(folder.path)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(JarasTheme.line).frame(width: 1)
                VStack(alignment: .leading, spacing: 8) {
                    Text("All regions preview").font(.jarasCaption.bold()).foregroundStyle(JarasTheme.secondary)
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(selection.selected.enumerated()), id: \.element) { entry in
                                HStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 2).fill(JarasTheme.green).frame(width: 3)
                                    Text(String(format: "%02d", entry.offset + 1))
                                        .font(.jarasSystem(size: 10, design: .monospaced)).foregroundStyle(JarasTheme.secondary)
                                        .frame(minWidth: 20, alignment: .leading)
                                    Text(entry.element.lastPathComponent).font(.jarasSystem(size: 13, weight: .semibold))
                                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(.horizontal, 8).padding(.vertical, 7).frame(height: rowHeight)
                                    .background(JarasTheme.panel, in: RoundedRectangle(cornerRadius: 5))
                                    .jarasHelp(entry.element.path)
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue") { confirm(selection.selected) }
                    .buttonStyle(StageButtonStyle(color: JarasTheme.green))
                    .keyboardShortcut(.defaultAction).disabled(selection.selected.isEmpty)
            }
        }
    }
}
