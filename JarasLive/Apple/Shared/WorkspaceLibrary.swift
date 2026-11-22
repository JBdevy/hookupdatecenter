import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

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

#if os(macOS)
/// Keep live widths inside this sidebar. Publishing them through MainView
/// replaces the grid and Setlist hosting roots on every pointer movement.
struct DesktopLibraryPane: View {
    let theme: JarasInterfaceTheme
    let show: ShowController
    let available: CGFloat
    @AppStorage("jaras.layout.library.width", store: WorkspaceLayoutPreferences.storage) private var saved = 344.0
    @AppStorage(WorkspaceLibrary.folderWidthKey, store: WorkspaceLayoutPreferences.storage) private var folders = WorkspaceLibrary.defaultFolderWidth
    @State private var liveWidth: Double?
    var body: some View {
        let maximum = WorkspaceLibrary.maximumWidth(folders: folders, available: available)
        let width = min(maximum, liveWidth ?? saved)
        ResizableWorkspaceLibrary(theme: theme, show: show, width: width, maximumWidth: maximum,
            preferredWidth: Binding(get: { liveWidth ?? saved }, set: { if $0 != liveWidth { liveWidth = $0 } }),
            finishOuterResize: {
                if let liveWidth, liveWidth != saved { saved = liveWidth }
                liveWidth = nil
            })
            .frame(width: width)
    }
}
#endif

private func clampedFolderWidth(_ requested: CGFloat, panel: CGFloat) -> CGFloat {
    let minimum = min(90, panel / 2)
    return min(max(minimum, requested), max(minimum, panel - 99))
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

    @AppStorage(WorkspaceLibrary.folderWidthKey, store: WorkspaceLayoutPreferences.storage)
    private var folderWidth = WorkspaceLibrary.defaultFolderWidth
    @State private var dragStart: CGFloat?

    var body: some View {
        WorkspaceLibrary(theme: theme, show: show)
            .overlay(alignment: .trailing) {
                libraryResizeEdge(theme: theme, label: "Resize Library", value: width, maximum: maximumWidth,
                                  affectsTimeline: true, start: $dragStart,
                                  ended: { finishOuterResize?() }) {
                    let minimum = min(maximumWidth, clampedFolderWidth(folderWidth, panel: width) + 99)
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
    @AppStorage(WorkspaceLibrary.folderWidthKey, store: WorkspaceLayoutPreferences.storage)
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
    @Binding var text: String
    var body: some View {
        Group {
            #if os(macOS)
            TextItemNotepad(text: $text, apply: {}, cancel: {})
            #else
            NativeFullLyricsInput(text: $text, outlineStanzas: false,
                                  font: UIFont(name: CatLiveTypeface.name(nil), size: 15) ?? .systemFont(ofSize: 15))
            #endif
        }.accessibilityLabel("Notes").padding(5)
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
        ScrollView {
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

struct WorkspaceNotesDock: View {
    let theme: JarasInterfaceTheme
    @AppStorage(LibraryNote.storageKey, store: WorkspaceLayoutPreferences.storage) private var storedNotes = Data()
    @State private var selection: UUID?
    @State private var namingNote: LibraryNote?
    @State private var showingPicker = false

    private var notes: [LibraryNote] { LibraryNote.decode(storedNotes) }
    private var activeNote: LibraryNote? { notes.first { $0.id == selection } ?? notes.first }

    var body: some View {
        VStack(spacing: 0) {
            LibraryDockPickerButton(title: "Notes", current: activeNote?.title ?? JarasLocalization.string("Notes")) {
                namingNote = nil
                showingPicker.toggle()
            }
            .padding(5)
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
            if let note = activeNote {
                LibraryNoteEditor(text: Binding(
                    get: { notes.first { $0.id == note.id }?.text ?? "" },
                    set: { text in
                        var updated = notes
                        guard let index = updated.firstIndex(where: { $0.id == note.id }) else { return }
                        updated[index].text = text
                        persist(updated)
                    }
                )).id(note.id)
            } else {
                Color.clear
            }
        }.frame(maxHeight: .infinity, alignment: .top)
            .background(theme.mixerPanelBackground).foregroundStyle(JarasTheme.text)
    }

    private func persist(_ notes: [LibraryNote]) {
        if let encoded = try? JSONEncoder().encode(notes) { storedNotes = encoded }
    }
}
struct WorkspaceLibrary: View {
    static let folderWidthKey = "jaras.library.foldersWidth"
    static let defaultFolderWidth = 146.0
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
        case preset(String)
        case favoritePlugins, favoriteSamplers
        case annotation(UUID)
        case regions, markers
    }


    private struct SamplerCategory: Codable, Identifiable {
        var id = UUID()
        let name: String
    }

    private struct Sampler: Identifiable {
        let url: URL
        var id: URL { url }
        var favoriteKey: String { url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    private static let nativeSampleRoot = Bundle.main.resourceURL?.appendingPathComponent("NativeSamples", isDirectory: true)
    private static let nativeSampleCategories = ["Cymbals", "FX", "FX Brazil", "Kick", "Percussion", "Snare", "Toms"]

    private static let nativeTypes: [String: String] = [
        "EQ": "EQ", "Compressor": "Dynamics", "Pitch": "Pitch Shift", "Delay": "Delay",
        "Reverb": "Reverb", "Limiter": "Dynamics", "CatLive Trigger": "Trigger", "Cat Gate": "Dynamics",
        "Chorus": "Modulation", "Phaser": "Modulation", "Amp": "Distortion", "Soft Clipper": "Dynamics", "Gate Divisor": "Dynamics", "Arpeggiator": "MIDI", "Drummer Pad 16": "Instrument", "Drummer Pad 48": "Instrument"
    ]

    let theme: JarasInterfaceTheme
    let show: ShowController
    var samplersOnly = false
    @ObservedObject private var instruments = InstrumentLibrary.shared
    #if os(macOS)
    @ObservedObject private var plugins = PluginCatalog.shared
    #endif
    @AppStorage(LibraryNote.storageKey, store: WorkspaceLayoutPreferences.storage) private var storedNotes = Data()
    @AppStorage("jaras.library.samplerCategories", store: WorkspaceLayoutPreferences.storage) private var storedSamplerCategories = Data()
    @AppStorage("jaras.library.favorites", store: WorkspaceLayoutPreferences.storage) private var storedFavorites = Data()
    @AppStorage("jaras.library.samplerPreviewDB", store: WorkspaceLayoutPreferences.storage) private var samplerPreviewDB = 0.0
    @State private var instrumentsExpanded = false
    @State private var pluginsExpanded = false
    @State private var samplersExpanded = false
    @State private var midiExpanded = false
    @State private var userExpanded = false
    @State private var presetsExpanded = false
    @State private var favoritesExpanded = false
    @State private var annotationExpanded = false
    @State private var namingNote: LibraryNote?
    @State private var creatingCategory = false
    @State private var showingSamplerPicker = false
    @State private var categoryName = ""
    @State private var categoryToDelete: SamplerCategory?
    @State private var deletingPadSamples = false
    @State private var hasPadSamples = false
    @State private var categoryDeletionError: String?
    @State private var pickingSamplers = false
    @State private var samplerDestination: SamplerCategory?
    @State private var samplerFiles: [Sampler] = []
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
        let externalTypes = catalog.plugins.flatMap(\.types)
        #else
        let externalTypes: [String] = []
        #endif
        return (["All", "Native"] + pluginTypes(externalTypes: externalTypes)).map { title in
            var entries = NativeFXSettings.order.compactMap { name -> (identity: String, name: String)? in
                guard let type = nativeTypes[name], title == "All" || title == "Native" || title == type else { return nil }
                return ("native:" + name, name == "Limiter" ? "CatLive Limiter" : name)
            }
            #if os(macOS)
            if title != "Native" {
                entries += catalog.matchingPlugins(query: "", type: title == "All" ? "" : title, vendor: "", allowsInstruments: true)
                    .map { ("vst3:" + $0.classID, $0.name) }
            }
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
        if hasPadSamples { entries.append((name: "Pads", target: .padSamplers)) }
        entries.append(contentsOf: Self.nativeSampleCategories.map { (name: $0, target: .nativeSamplers($0)) })
        return entries
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
            ScrollView {
                VStack(spacing: 2) {
                    folder("Instruments", expanded: $instrumentsExpanded, shaded: false, icon: "library.instruments")
                        .contextMenu {
                            Button("Import SF2…", action: chooseSoundFonts).disabled(importingSoundFonts)
                        }
                    if instrumentsExpanded {
                        ForEach(Array(InstrumentCategory.allCases.enumerated()), id: \.element) { index, category in
                            navigationRow(category == .pianos ? "Grand Pianos" : category.rawValue,
                                          icon: "folder.fill", target: .instrument(category), shaded: index.isMultiple(of: 2))
                        }
                    }
                    Divider().padding(.vertical, 3)
                    folder("Plugins", expanded: $pluginsExpanded, shaded: true, icon: "library.plugins")
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
                                categoryInput
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
                        if hasPadSamples {
                            navigationRow("Pads", icon: "folder.fill", target: .padSamplers, shaded: true)
                                .contextMenu { Button("Delete", role: .destructive) { deletingPadSamples = true } }
                        }
                        ForEach(Array(Self.nativeSampleCategories.enumerated()), id: \.element) { index, category in
                            navigationRow(category, icon: "folder.fill", target: .nativeSamplers(category),
                                          shaded: index.isMultiple(of: 2))
                        }
                    }
                    divider
                    folder("Midi", expanded: $midiExpanded, shaded: true, icon: "pianokeys")
                    if midiExpanded {
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
                    samplerToolbar
                    samplerDropArea(details)
                }
            } else {
                LibraryColumns(theme: theme, folders: folders, entries: VStack(spacing: 0) {
                    if showsSearch { searchField }
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
        .onAppear {
            refreshPadSamples()
            if samplersOnly {
                if selection == nil {
                    selection = samplerPickerEntries.first?.target
                }
            } else {
                instruments.refresh(); loadPresets()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: VinhetasController.padSamplesChanged)) { _ in refreshPadSamples() }
        .onDisappear { stopPreview() }
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
            case .samplerCategory, .padSamplers, .nativeSamplers, .favoriteSamplers: loadSamplers()
            default: break
            }
        }
    }

    private var folderToolbar: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                instrumentsExpanded = false
                pluginsExpanded = false
                samplersExpanded = false
                midiExpanded = false
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
        Button { selection = target } label: {
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
                .accessibilityIdentifier("library-category-search")
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
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
        case .midiChords(let category):
            ScrollView {
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
            LibraryTimelineList(show: show, regions: selection == .regions, matches: matchesSearch)
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
            ScrollView {
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
            Image(systemName: icon).font(.jarasSystem(size: 11, weight: .medium)).foregroundStyle(theme.secondary)
            Text(verbatim: name).font(.jarasSystem(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func pluginList(type: String? = nil, favoritesOnly: Bool = false) -> some View {
        #if os(macOS)
        let external = type == "Native" ? [] : plugins.matchingPlugins(query: "", type: favoritesOnly ? PluginCatalog.favoritesType : type ?? "",
                                               vendor: "", allowsInstruments: true).filter { matchesSearch($0.name) }
        #endif
        let native = NativeFXSettings.order.filter {
            guard let category = Self.nativeTypes[$0], matchesSearch(pluginName("native:" + $0)) else { return false }
            if favoritesOnly { return favoriteKeys.contains("native:" + $0) }
            return type == nil || type == "Native" || category == type
        }
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(native.enumerated()), id: \.element) { index, name in
                    let key = "native:" + name
                    pluginRow(pluginName(key), identity: key, shaded: index.isMultiple(of: 2),
                              favorite: favoriteKeys.contains(key)) { toggleFavorite(key) }
                }
                #if os(macOS)
                ForEach(Array(external.enumerated()), id: \.element.id) { index, plugin in
                    pluginRow(plugin.name, identity: "vst3:" + plugin.classID, shaded: (native.count + index).isMultiple(of: 2),
                              favorite: plugins.isFavorite(plugin)) { plugins.toggleFavorite(plugin) }
                }
                #endif
            }
            .padding(6)
        }
    }

    private func pluginRow(_ name: String, identity: String, shaded: Bool, favorite: Bool, toggle: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            entryName(name, icon: "puzzlepiece.extension")
                .contentShape(Rectangle())
                .modifier(effectDrag(name, identity: identity))
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
            Image(systemName: favorite ? "star.fill" : "star")
                .font(.jarasSystem(size: 10, weight: .medium))
                .foregroundStyle(favorite ? JarasTheme.yellow : theme.secondary)
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
        return ScrollView {
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

    private func annotation(_ id: UUID) -> some View {
        LibraryNoteEditor(text: Binding(
            get: { notes.first(where: { $0.id == id })?.text ?? "" },
            set: { text in
                var updated = notes
                guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
                updated[index].text = text
                saveNotes(updated)
            }
        )).id(id)
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
            if creatingCategory { categoryInput }
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

    private var categoryInput: some View {
        let name = categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = !name.isEmpty && !samplerCategories.contains { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Create category").font(.jarasSystem(size: 13, weight: .semibold))
            TextField("Name", text: $categoryName)
                .onChange(of: categoryName) { name in
                    if name.count > 12 { categoryName = String(name.prefix(12)) }
                }
                .onSubmit { if valid { createCategory(name) } }
            Button("Create") { createCategory(name) }.disabled(!valid)
        }.padding(12).frame(width: 195)
    }

    private func createCategory(_ name: String) {
        let category = SamplerCategory(name: String(name.prefix(12)))
        guard let encoded = try? JSONEncoder().encode(samplerCategories + [category]) else { return }
        storedSamplerCategories = encoded
        userExpanded = true
        selection = .samplerCategory(category.id)
        creatingCategory = false
        showingSamplerPicker = false
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
        hasPadSamples = !padSamplers().isEmpty
        if !hasPadSamples && selection == .padSamplers { selection = nil }
        if selection == .padSamplers || selection == .favoriteSamplers { loadSamplers() }
    }

    private func padSamplers() -> [Sampler] {
        samplers(in: VinhetasController.shared.padSampleDirectory).filter { VinhetasPad.accepts($0.url) }
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
        samplerError = ""
        switch selection {
        case .samplerCategory(let id):
            samplerFiles = samplers(in: try? Self.samplerDirectory(id))
        case .padSamplers:
            samplerFiles = padSamplers()
        case .nativeSamplers(let name):
            samplerFiles = nativeSamplers(in: name)
        case .favoriteSamplers:
            let keys = favoriteKeys
            let user = samplerCategories.flatMap { samplers(in: try? Self.samplerDirectory($0.id)) }
            let native = Self.nativeSampleCategories.flatMap { nativeSamplers(in: $0) }
            samplerFiles = (user + padSamplers() + native).filter { keys.contains($0.favoriteKey) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        default:
            samplerFiles = []
        }
    }

    private func nativeSamplers(in name: String) -> [Sampler] {
        samplers(in: Self.nativeSampleRoot?.appendingPathComponent(name, isDirectory: true))
            .filter { VinhetasPad.accepts($0.url) }
    }

    private func samplers(in directory: URL?) -> [Sampler] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map(Sampler.init(url:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var samplerList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ControlIcon(name: "speaker.wave.2", size: 14)
                Slider(value: $samplerPreviewDB, in: -60...0, step: 1)
                    .tint(JarasTheme.green)
                    .accessibilityLabel("Sample preview volume")
                Text(verbatim: samplerPreviewDB <= -60 ? "−∞ dB" : String(format: "%.0f dB", samplerPreviewDB))
                    .font(.jarasSystem(size: 10)).monospacedDigit().lineLimit(1).frame(width: 37, alignment: .trailing)
            }.padding(.horizontal, 6).frame(height: 32)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(samplerFiles.filter { matchesSearch($0.name) }.enumerated()), id: \.element.id) { index, sampler in
                        let playing = preview?.url == sampler.url
                        HStack(spacing: 0) {
                            Button { togglePreview(sampler.url) } label: {
                                HStack(spacing: 0) {
                                    entryName(sampler.name, icon: "waveform").padding(.leading, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: playing ? "stop.fill" : "play.fill")
                                        .font(.jarasSystem(size: 9, weight: .semibold))
                                        .foregroundStyle(playing ? JarasTheme.green : theme.secondary)
                                        .frame(width: 24)
                                }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel(Text(verbatim: sampler.name))
                                .accessibilityHint(playing ? Text("Stop") : Text("Play"))
                                .modifier(LibraryRowDrag(title: sampler.name, type: LibrarySamplerTransfer.type,
                                    data: { Data(sampler.url.absoluteString.utf8) },
                                    provider: { LibrarySamplerTransfer.provider(sampler.url) },
                                    click: { togglePreview(sampler.url) }))
                            favoriteButton(favoriteKeys.contains(sampler.favoriteKey)) { toggleFavorite(sampler.favoriteKey) }
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

    @discardableResult nonisolated static func copySampler(_ source: URL, into directory: URL, reuseIdentical: Bool = false) throws -> URL {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent("." + UUID().uuidString).appendingPathExtension(source.pathExtension)
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: source, to: temporary)
        let audio = try AVAudioFile(forReading: temporary)
        guard VinhetasPad.acceptsDuration(frames: audio.length, sampleRate: audio.fileFormat.sampleRate) else {
            throw ProjectError.invalid(JarasLocalization.string("Samplers must be between 0 and 60 seconds."))
        }
        let base = source.deletingPathExtension().lastPathComponent
        var target = directory.appendingPathComponent(source.lastPathComponent)
        var copyNumber = 2
        while true {
            do {
                try manager.moveItem(at: temporary, to: target)
                return target
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                if reuseIdentical && manager.contentsEqual(atPath: temporary.path, andPath: target.path) { return target }
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
                let buffer: AVAudioPCMBuffer
                if let instrumentID {
                    let drums = InstrumentLibrary.category(instrumentID) == .drum
                    buffer = try await LibrarySoundFontPreviewRenderer.shared.render(url, drums: drums)
                } else {
                    buffer = try await Task.detached(priority: .userInitiated) { try Self.decodeSampler(url) }.value
                }
                guard !Task.isCancelled, preview?.id == id else { return }
                try playback.playLibrarySampler(id, buffer: buffer, gain: instrumentID == nil ? samplerPreviewGain : 1) {
                    if preview?.id == id { preview = nil }
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

    nonisolated private static func decodeSampler(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard VinhetasPad.acceptsDuration(frames: file.length, sampleRate: format.sampleRate) else {
            throw ProjectError.invalid(JarasLocalization.string("Samplers must be between 0 and 60 seconds."))
        }
        let frames = min(Double(file.length), (format.sampleRate * 3).rounded(.down))
        guard frames >= 1, frames <= Double(UInt32.max) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try PadAudioBuffer.read(file, frames: AVAudioFrameCount(frames))
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
                guard NativeFXSettings.order.contains(kind) else { return nil }
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
            guard !original.inserted.contains(key) else { return nil }
            let library = try FXPresetStore.shared.read()
            if let presetID {
                guard let preset = library.presets.first(where: { $0.id == presetID }) else { throw ProjectError.invalid("Preset not found for this plugin") }
                settings = try preset.applying(to: settings, effect: key)
            } else {
                settings = try library.applyingDefault(to: settings, effect: key)
            }
            if let target, let index = original.inserted.firstIndex(of: target) {
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
    private struct Entry: Identifiable {
        let id: UUID
        let name: String
        let label: String
        let position: Double
    }

    let show: ShowController
    let regions: Bool
    let matches: (String) -> Bool
    @ObservedObject private var presentation: ShowProjectPresentation
    @State private var selected: UUID?
    @State private var editing: UUID?
    @State private var draft = ""
    @State private var original = ""

    init(show: ShowController, regions: Bool, matches: @escaping (String) -> Bool) {
        self.show = show; self.regions = regions; self.matches = matches
        presentation = show.projectPresentation
    }

    private var entries: [Entry] {
        guard let song = show.current else { return [] }
        let values: [Entry]
        if regions {
            values = song.parts.map { Entry(id: $0.id, name: $0.name, label: $0.displayName, position: $0.startTime) }
        } else {
            values = (song.markers ?? []).filter {
                !$0.isTempo && !$0.isSection && $0.unifiedRegionID == nil && $0.sourceRegionID == nil
            }.map { Entry(id: $0.id, name: $0.name, label: $0.name, position: $0.position) }
        }
        return values.filter { matches($0.label) || $0.id == editing }.sorted { $0.position < $1.position }
    }

    var body: some View {
        let rows = entries
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        Group {
                            if editing == row.id {
                                nameInput(for: row, index: index, rows: rows)
                            } else {
                                rowLabel(row)
                            }
                        }
                        .frame(height: 25)
                        .background(selected == row.id ? JarasTheme.green.opacity(0.24) : Color.white.opacity(index.isMultiple(of: 2) ? 0.045 : 0),
                                    in: RoundedRectangle(cornerRadius: 4))
                        .id(row.id)
                    }
                }.padding(6)
            }
            .onChange(of: editing) { id in
                if let id { scroll.scrollTo(id) }
            }
        }
        .onChange(of: show.current?.id) { _ in editing = nil; selected = nil }
        .onChange(of: regions) { _ in editing = nil; selected = nil }
        .onChange(of: rows.map(\.id)) { ids in
            if let editing, !ids.contains(editing) { self.editing = nil }
        }
    }

    private func rowLabel(_ row: Entry) -> some View {
        let label = Text(verbatim: row.label).font(.jarasSystem(size: 12))
            .lineLimit(1).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 6).contentShape(Rectangle())
        return Group {
            #if os(macOS)
            label.onTapGesture { select(row) }
                .immediateRightClick { DispatchQueue.main.async { begin(row) } }
            #else
            label.overlay { IpadTapHoldTouchSurface(tap: { select(row) }, hold: { begin(row) }) }
            #endif
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.label))
        .accessibilityAddTraits(selected == row.id ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select(row) }
        .accessibilityAction(named: Text("Rename")) { begin(row) }
    }

    private func select(_ row: Entry) {
        guard show.selectLibraryTimelineEntry(row.id, region: regions) else { return }
        selected = row.id
    }

    private func begin(_ row: Entry) {
        if let editing, editing != row.id { finish(editing) }
        guard show.canControl() else { return }
        original = row.name; draft = row.name; editing = row.id
    }

    private func finish(_ id: UUID, save: Bool = true) {
        guard editing == id else { return }
        editing = nil
        if save, draft != original { show.renameTimelineLabel(id, name: draft, region: regions) }
    }

    private func nameInput(for row: Entry, index: Int, rows: [Entry]) -> some View {
        let move: (Int) -> Void = { direction in
            guard editing == row.id, rows.indices.contains(index + direction) else { return }
            let next = rows[index + direction]
            finish(row.id)
            begin(next)
        }
        #if os(macOS)
        return LibraryTimelineNameInput(text: $draft, finish: { finish(row.id, save: $0) }, move: move)
        #else
        return InlineNameInput(text: $draft, compact: false, finish: { finish(row.id) }, move: move,
                        accessibilityName: regions ? "Region name" : "Marker name")
        #endif
    }
}

#if os(macOS)
private struct LibraryTimelineNameInput: NSViewRepresentable {
    @Binding var text: String
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
            case #selector(NSResponder.moveUp(_:)): input?.move(-1)
            case #selector(NSResponder.moveDown(_:)): input?.move(1)
            default: return false
            }
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
