import SwiftUI
import UniformTypeIdentifiers
@MainActor private final class SetlistEntryCache {
    struct Key: Equatable {
        let controller: ObjectIdentifier
        let project: UUID
        let projectRevision: UInt64
        let setlistRevision: UInt64
        let song: UUID?
        let playlist: UUID?
        let expanded: Set<UUID>
    }
    private var key: Key?
    private var cached: [SetlistEntry] = []
    func entries(for key: Key, build: () -> [SetlistEntry]) -> [SetlistEntry] {
        if self.key == key { return cached }
        cached = build(); self.key = key
        return cached
    }
}
struct SongListView: View {
    @ObservedObject var show: ShowController
    private struct EntryEdit: Identifiable { let id: UUID; let name: String; let color: UInt32; let block: Bool }
    @State private var editingEntry: EntryEdit?
    @State private var entryCache = SetlistEntryCache()
    @State private var expandedRegions: Set<UUID> = []
    private struct EntryRemoval {
        let ids: Set<UUID>
        let project: UUID
        let song: UUID
        let playlist: UUID?
        let keyboard: Bool
    }
    @State private var removal: EntryRemoval?
    @State private var confirmingRemoval = false
    @AppStorage("jaras.blocks.symbol") private var defaultBlockSymbol = true
    @State private var editingBlockSymbol = true
    @State private var editingUppercaseName = true
    @State private var showingBlockDefaults = false
    @State private var blockSymbolDraft = true
    @State private var createdBlock: UUID?
    @State private var selectedEntries: Set<UUID> = []
    @State private var entrySelectionAnchor: UUID?
    @State private var choosingPlaylist = false
    @State private var creatingPlaylist = false
    @State private var showingAutoOptions = false
    @State private var searching = false
    @State private var query = ""
    @State private var playlistName = ""
    @State private var missingPlaylistName = false
    @State private var nameShake = 0.0
    @FocusState private var playlistNameFocused: Bool
    @State private var selection: Set<UUID> = []
    @State private var selectionAnchor: UUID?
    @FocusState private var searchFocused: Bool
    private func requestRemoval(_ ids: Set<UUID>, keyboard: Bool) {
        guard !creatingPlaylist, !choosingPlaylist, !searching, editingEntry == nil,
              let song = show.current else { return }
        let allowed = show.deletableSetlistEntries(ids)
        guard !allowed.isEmpty else { return }
        removal = EntryRemoval(ids: allowed, project: show.snapshot.project.id, song: song.id,
                               playlist: show.selectedRegionPlaylist?.id, keyboard: keyboard)
        confirmingRemoval = true
    }
    private func selectEntry(_ id: UUID, visible: [SetlistEntry]) {
        #if os(macOS)
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let extending = flags.contains(.shift)
        let toggling = flags.contains(.command) || flags.contains(.control)
        #else
        let extending = false, toggling = false
        #endif
        if extending, let anchor = entrySelectionAnchor,
           let first = visible.firstIndex(where: { $0.id == anchor }), let last = visible.firstIndex(where: { $0.id == id }) {
            let range = Set(visible[min(first,last)...max(first,last)].map(\.id))
            selectedEntries = toggling ? selectedEntries.union(range) : range
        } else if toggling {
            if !selectedEntries.insert(id).inserted { selectedEntries.remove(id) }
            entrySelectionAnchor = id
        } else {
            selectedEntries = [id]; entrySelectionAnchor = id
            if let entry = visible.first(where: { $0.id == id }), case .region = entry { show.focusRegion(id) }
        }
    }
    var body: some View {
        let visible = entryCache.entries(for: SetlistEntryCache.Key(controller: ObjectIdentifier(show), project: show.snapshot.project.id, projectRevision: show.projectRevision, setlistRevision: show.setlistRevision, song: show.current?.id, playlist: show.regionSetlist.selectedId, expanded: expandedRegions)) {
            let children = Dictionary(grouping: (show.current?.parts ?? []).filter { $0.parentRegionID != nil }, by: { $0.parentRegionID! })
            return show.setlistEntries.flatMap { entry -> [SetlistEntry] in
                guard expandedRegions.contains(entry.id) else { return [entry] }
                let nested = (children[entry.id] ?? []).sorted { $0.startTime == $1.startTime ? $0.endTime < $1.endTime : $0.startTime < $1.startTime }
                return [entry] + nested.enumerated().map { .region($0.element, number: $0.offset + 1) }
            }
        }
        let transport = show.snapshot.transport
        let playing = transport.playing ? show.current?.parts.first(where: { $0.id == transport.regionId }) : nil
        let playingBounds = playing?.parentRegionID.flatMap { parent in show.current?.parts.first(where: { $0.id == parent }) } ?? playing
        let displayedPlaying = transport.playing ? show.current?.playingSetlistRegion(transport.regionId, position: transport.position, expanded: expandedRegions) : nil
        VStack(spacing: 0) {
            HStack {
                Text("SETLIST").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(JarasTheme.secondary)
                Spacer()
            }.padding(.horizontal, 8)
            HStack(spacing: 3) {
                Button { choosingPlaylist.toggle() } label: {
                    HStack(spacing: 3) {
                        Group { if let playlist = show.selectedRegionPlaylist { Text(playlist.name) } else { Text("All regions") } }.lineLimit(1)
                        Spacer(minLength: 3)
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }.font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 7).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.45)))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).jarasHelp("Choose playlist")
                    .popover(isPresented: $choosingPlaylist, arrowEdge: .bottom) { playlistPanel }
                Button {
                    playlistName = ""; missingPlaylistName = false; nameShake = 0; selection = []; selectionAnchor = nil
                    choosingPlaylist = false; creatingPlaylist = true
                } label: { Image(systemName: "plus").frame(width: 27, height: 30).contentShape(Rectangle()) }
                    .buttonStyle(.plain).jarasHelp("Create playlist").accessibilityLabel("Create playlist")
                Button { searching.toggle() } label: {
                    Image(systemName: "magnifyingglass").foregroundStyle(query.isEmpty ? .white : JarasTheme.green)
                        .frame(width: 27, height: 30).contentShape(Rectangle())
                }.buttonStyle(.plain).jarasHelp("Search songs (Tab)").accessibilityLabel("Search songs")
                    .popover(isPresented: $searching) { searchPanel }
                Button { show.toggleRegionAuto() } label: {
                    Text("AUTO").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(show.regionSetlist.autoAdvance ? .black : JarasTheme.secondary)
                        .frame(width: 34, height: 26)
                        .background(show.regionSetlist.autoAdvance ? JarasTheme.green : JarasTheme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 4)).contentShape(Rectangle())
                }.buttonStyle(.plain).jarasHelp("Queue the next song automatically")
                    .immediateRightClick { showingAutoOptions = true }
                    .popover(isPresented: $showingAutoOptions) {
                        Toggle("Without playback", isOn: Binding(get: { show.regionSetlist.preparesWithoutPlayback }, set: { show.setPrepareWithoutPlayback($0) }))
                            .toggleStyle(.automatic).padding(18)
                    }
                Button { createdBlock = show.addSetlistBlock(symbol: defaultBlockSymbol, namePrefix: JarasLocalization.string("Bloco")) } label: {
                    Text("Blocks").font(.system(size: 9, weight: .bold)).padding(.horizontal, 6).frame(height: 26)
                        .background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 4)).contentShape(Rectangle())
                }.buttonStyle(.plain).jarasHelp("Add a setlist block").accessibilityLabel("Blocks")
                    .immediateRightClick {
                        guard show.selectedRegionPlaylist != nil else { return }
                        blockSymbolDraft = defaultBlockSymbol; showingBlockDefaults = true
                    }
                    .disabled(show.selectedRegionPlaylist == nil)
                    .opacity(show.selectedRegionPlaylist == nil ? 0.4 : 1)
                RegionStopButton(active: show.regionSetlist.stopsAtRegionEnd) { show.toggleRegionStop() }
            }.padding(.horizontal, 8).padding(.bottom, 6)
            ScrollViewReader { scroll in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(visible) { entry in
                            switch entry {
                            case .block(let block):
                                SetlistBlockRow(block: block)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(selectedEntries.contains(block.id) ? JarasTheme.green : .clear, lineWidth: 1))
                                    .onTapGesture { selectEntry(block.id, visible: visible) }
                                    .immediateRightClick { editingBlockSymbol = block.showsSymbol; editingEntry = EntryEdit(id: block.id, name: block.name, color: block.color, block: true) }
                                    .modifier(PlaylistRegionDrag(show: show, playlist: show.selectedRegionPlaylist?.id, entry: block.id, block: true, selection: $selectedEntries))
                                    .id(block.id)
                            case .region(let region, let number):
                            let active = displayedPlaying?.id == region.id
                            let queued = transport.playing && transport.queuedRegionId == region.id
                            let duration = region.endTime - region.startTime
                            let remaining = active ? max(0, region.endTime - transport.position) : duration
                            let progress = active ? min(1, max(0, (transport.position - region.startTime) / duration)) : 0
                            let queueRemaining = queued ? max(0, (playingBounds?.endTime ?? transport.position) - transport.position) : 0
                            let queueLength = max(0.001, (playingBounds?.endTime ?? transport.position) - (transport.queueStartedAt ?? transport.position))
                            RegionSetlistRow(region: region, number: number, selected: selectedEntries.contains(region.id),
                                             active: active, queued: queued, prepareOnly: show.regionSetlist.preparesWithoutPlayback, remaining: Int(ceil(remaining)),
                                             progress: progress, queueProgress: queued ? min(1, queueRemaining / queueLength) : 0,
                                             expanded: show.current?.parts.contains(where: { $0.parentRegionID == region.id }) == true ? expandedRegions.contains(region.id) : nil,
                                             toggleDrawer: {
                                                 if !expandedRegions.insert(region.id).inserted { expandedRegions.remove(region.id) }
                                             }) {
                                selectEntry(region.id, visible: visible)
                            }.equatable().padding(.leading, region.parentRegionID == nil ? 0 : 18)
                                .contextMenu {
                                    Button("Edit song") { editingUppercaseName = region.usesUppercase; editingEntry = EntryEdit(id: region.id, name: region.name, color: region.color ?? 0x705264, block: false) }
                                    if show.current?.parts.contains(where: { $0.parentRegionID == region.id }) == true {
                                        Button("Disunify") { show.disunifyRegion(region.id); expandedRegions.remove(region.id) }
                                    }
                                    if region.parentRegionID == nil {
                                    Button(show.selectedRegionPlaylist == nil ? "Delete region" : "Remove from playlist", role: .destructive) {
                                        requestRemoval([region.id], keyboard: false)
                                    }
                                    }
                                }
                                .modifier(PlaylistRegionDrag(show: show, playlist: show.selectedRegionPlaylist?.id, entry: region.id, block: false, selection: $selectedEntries, locked: region.parentRegionID != nil))
                                .id(region.id)
                            }
                        }
                        if visible.isEmpty {
                            Text("Select an item and press Shift + R to create a region.")
                                .font(.caption).foregroundStyle(JarasTheme.secondary).padding(12)
                        }
                    }.padding(.horizontal, 8)
                    #if os(macOS)
                    .background(SetlistScrollbarsHidden())
                    #endif
                }.onChange(of: show.focusedRegion) { id in
                    if let id, let parent = show.current?.parts.first(where: { $0.id == id })?.parentRegionID { expandedRegions.insert(parent) }
                    if let id { selectedEntries = [id]; entrySelectionAnchor = id; scroll.scrollTo(id) }
                }
                    .onChange(of: selectedEntries) { AudioExportSelection.shared.setRegions($0, song: show.current?.id) }
                    .onChange(of: show.selectedRegionPlaylist?.id) { _ in selectedEntries = []; entrySelectionAnchor = nil }
                    .onChange(of: show.snapshot.project.id) { _ in selectedEntries = []; entrySelectionAnchor = nil }
                    .onChange(of: show.regionFocusRequest) { request in
                        // Apply after the destination playlist has laid out, including repeated results.
                        DispatchQueue.main.async {
                            guard show.regionFocusRequest == request, let id = show.focusedRegion else { return }
                            selectedEntries = [id]; entrySelectionAnchor = id
                            scroll.scrollTo(id)
                        }
                    }
                    .onChange(of: createdBlock) { id in if let id { scroll.scrollTo(id, anchor: .top) } }
            }
        }
        .overlay(alignment: .top) {
            if creatingPlaylist { creationPanel }
        }
        #if os(macOS)
         .background(SetlistArrowKeys(search: {
            guard !creatingPlaylist else { return false }
            choosingPlaylist = false
            searching = true
            searchFocused = true
            return true
        }, move: {
            guard !creatingPlaylist && !choosingPlaylist else { return false }
            show.stepRegion($0, entries: visible, commitAfterDelay: false)
            return true
        }, released: { show.finishRegionNavigation() }, delete: { requestRemoval(selectedEntries, keyboard: true) }))
        #endif
        .onChange(of: show.setlistNavigationRequest) { request in
            guard let request, !creatingPlaylist && !choosingPlaylist else { return }
            show.stepRegion(request.direction, entries: visible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(hex: 0x151b22))
        .alert(removal?.keyboard == true ? "Delete the selected setlist items?" : removal?.playlist == nil ? "Delete this region?" : "Remove this song from the playlist?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) { removal = nil }
            Button("Delete", role: .destructive) {
                if let removal, removal.project == show.snapshot.project.id, removal.song == show.current?.id,
                   removal.playlist == show.selectedRegionPlaylist?.id, show.deleteSetlistEntries(removal.ids) {
                    selectedEntries.subtract(removal.ids)
                    expandedRegions.subtract(removal.ids)
                    if let entrySelectionAnchor, removal.ids.contains(entrySelectionAnchor) { self.entrySelectionAnchor = nil }
                }
                removal = nil
            }
        }
        .sheet(item: $editingEntry) { edit in
            NameColorEditor(title: edit.block ? "Edit block" : "Edit song", initialName: edit.name, initialColor: edit.color, save: { name, color in
                if edit.block { show.editSetlistBlock(edit.id, name: name, color: color, symbol: editingBlockSymbol) }
                else { show.editRegion(edit.id, name: name, color: color, uppercaseName: editingUppercaseName) }
            }, symbol: edit.block ? $editingBlockSymbol : nil, uppercaseName: edit.block ? nil : $editingUppercaseName).background(JarasTheme.panel)
        }
        .sheet(isPresented: $showingBlockDefaults) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Blocks").font(.headline)
                Toggle("SIMBOL", isOn: $blockSymbolDraft)
                HStack {
                    Button("Cancelar") { showingBlockDefaults = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Salvar") { defaultBlockSymbol = blockSymbolDraft; showingBlockDefaults = false }.keyboardShortcut(.defaultAction)
                }
            }.padding(18).frame(width: 280).background(JarasTheme.panel)
        }
    }
    private func chooseSearchResult(_ id: UUID) {
        guard show.selectRegionSearchResult(id) else { return }
        searching = false; query = ""; choosingPlaylist = false
    }
    private var searchPanel: some View {
        let results = show.searchRegions(query)
        return VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Search songs", text: $query).textFieldStyle(.roundedBorder).focused($searchFocused)
                    .onSubmit { if let first = results.first { chooseSearchResult(first.id) } }
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
            }
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 3) {
                    ForEach(results) { region in
                        Button { chooseSearchResult(region.id) } label: {
                            HStack(spacing: 8) {
                                Text(region.displayName).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(regionDurationText(region.endTime - region.startTime))
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(JarasTheme.secondary)
                            }.font(.system(size: 12)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(JarasTheme.background).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if results.isEmpty { Text("No results").font(.caption).foregroundStyle(JarasTheme.secondary).padding(12) }
                }
            }.frame(height: min(300, CGFloat(max(1, results.count)) * 34))
        }.padding(12).frame(width: 300).onAppear { searchFocused = true }
    }
    private var playlistPanel: some View {
                VStack(spacing: 2) {
                    HStack {
                        Text("Playlists").font(.headline); Spacer()
                        Button { choosingPlaylist = false } label: { Image(systemName: "xmark").frame(width: 30, height: 30).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Close playlists")
                    }
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 3) {
                            playlistChoice("All regions", id: nil)
                            ForEach(show.regionSetlist.playlists.filter { $0.songId == show.current?.id }) { list in
                                playlistChoice(list.name, id: list.id)
                            }
                        }
                    }.frame(maxHeight: 250)
                }.padding(10).background(JarasTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(JarasTheme.line))
                    .frame(width: 240)
    }
    private func playlistChoice(_ name: String, id: UUID?) -> some View {
        Button {
            show.selectRegionPlaylist(id); choosingPlaylist = false; query = ""
        } label: {
            HStack {
                Group { if id == nil { Text(LocalizedStringKey(name)) } else { Text(name) } }.lineLimit(1); Spacer()
                if show.regionSetlist.selectedId == id { Image(systemName: "checkmark").foregroundStyle(JarasTheme.green) }
            }.font(.system(size: 12)).padding(8).frame(maxWidth: .infinity)
                .background(JarasTheme.background).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private var creationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("New playlist").font(.system(size: 13, weight: .semibold)); Spacer()
                Button { creatingPlaylist = false } label: { Image(systemName: "xmark").frame(width: 30, height: 30).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Cancel playlist creation")
            }
            TextField("Playlist name", text: $playlistName).textFieldStyle(.roundedBorder)
                .focused($playlistNameFocused)
                .onSubmit(createPlaylist)
                .overlay {
                    RoundedRectangle(cornerRadius: 5).stroke(missingPlaylistName ? Color.red : .clear, lineWidth: 1.5)
                }
                .overlay(alignment: .topLeading) {
                    if missingPlaylistName {
                        Text("Escolha um nome")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(JarasTheme.text)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color(red: 0.7, green: 0.12, blue: 0.16))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .fixedSize().offset(x: 5, y: -21)
                            .allowsHitTesting(false)
                    }
                }
                .modifier(PlaylistNameShake(animatableData: nameShake))
                .onChange(of: playlistName) { value in
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missingPlaylistName = false }
                }
            HStack(spacing: 6) {
                Button("All") {
                    selection = Set(show.allRegions.map(\.id))
                    selectionAnchor = show.allRegions.first?.id
                }
                Button("Clear") { selection.removeAll(); selectionAnchor = nil }
                Spacer(minLength: 0)
            }.buttonStyle(StageButtonStyle()).controlSize(.small)
            Text("⌘ / Ctrl: multiple · Shift: range").font(.system(size: 9)).foregroundStyle(JarasTheme.secondary)
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 3) {
                    ForEach(show.allRegions) { region in
                        Button { selectForPlaylist(region.id) } label: {
                            HStack(spacing: 5) {
                                Text(region.displayName).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(regionDurationText(region.endTime - region.startTime)).font(.system(size: 9, design: .monospaced))
                            }.font(.system(size: 12)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selection.contains(region.id) ? JarasTheme.green.opacity(0.25) : JarasTheme.background)
                                .overlay(Rectangle().stroke(selection.contains(region.id) ? JarasTheme.green.opacity(0.7) : .clear))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        #if os(macOS)
                        .overlay(PlaylistSelectionClick { selectForPlaylist(region.id) })
                        #endif
                    }
                }
            }
            HStack {
                Text("\(selection.count)").font(.caption).foregroundStyle(JarasTheme.secondary)
                Spacer()
                Button("Create", action: createPlaylist)
                    .buttonStyle(StageButtonStyle(color: JarasTheme.green))
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty && !playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(selection.isEmpty && !playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            }
        }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(JarasTheme.panel).overlay(Rectangle().stroke(JarasTheme.line))
    }
    private func createPlaylist() {
        guard creatingPlaylist else { return }
        guard !playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            missingPlaylistName = true
            playlistNameFocused = true
            withAnimation(.linear(duration: 0.32)) { nameShake += 1 }
            return
        }
        guard !selection.isEmpty else { return }
        if show.createRegionPlaylist(name: playlistName, selected: selection) {
            creatingPlaylist = false; query = ""
        }
    }
    private func selectForPlaylist(_ id: UUID) {
        let ids = show.allRegions.map(\.id)
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor = selectionAnchor,
           let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: id) {
            let range = Set(ids[min(a,b)...max(a,b)])
            selection = flags.contains(.command) || flags.contains(.control) ? selection.union(range) : range
            return
        }
        if flags.contains(.command) || flags.contains(.control) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else { selection = [id] }
        #else
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        #endif
        selectionAnchor = id
    }
}
private struct RegionSetlistRow: View, Equatable {
    let region: Part
    let number: Int
    let selected: Bool
    let active: Bool
    let queued: Bool
    let prepareOnly: Bool
    let remaining: Int
    let progress: Double
    let queueProgress: Double
    var expanded: Bool? = nil
    var toggleDrawer: (() -> Void)? = nil
    let select: () -> Void
    static func == (a: Self, b: Self) -> Bool {
        a.region == b.region && a.number == b.number && a.selected == b.selected &&
        a.active == b.active && a.queued == b.queued && a.prepareOnly == b.prepareOnly && a.remaining == b.remaining &&
        a.progress == b.progress && a.queueProgress == b.queueProgress && a.expanded == b.expanded
    }
    var body: some View {
        let color = Color(hex: region.color ?? 0x705264)
        let numberWidth = CGFloat(max(2, String(number).count)) * 6
        Button(action: select) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(active ? Color.red : queued ? (prepareOnly ? JarasTheme.green : .orange) : color).frame(width: 3)
                Text(String(format: "%02d", number)).font(.system(size: 9, design: .monospaced)).foregroundStyle(JarasTheme.secondary)
                    .frame(width: numberWidth, alignment: .leading)
                if expanded != nil { Color.clear.frame(width: 12).allowsHitTesting(false) }
                Text(region.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(regionDurationText(Double(remaining))).font(.system(size: 9, weight: .medium, design: .monospaced)).monospacedDigit().fixedSize()
            }.padding(.horizontal, 8).padding(.vertical, 7).frame(height: 34).frame(maxWidth: .infinity)
                .background {
                    if active || queued {
                        LinearGradient(colors: active ? [Color(hex: 0x8b2026), Color(hex: 0x4c171c)] : prepareOnly ? [Color(hex: 0x19633a), Color(hex: 0x123b27)] : [Color(hex: 0xa84b13), Color(hex: 0x572808)], startPoint: .leading, endPoint: .trailing)
                    } else if selected {
                        LinearGradient(colors: [Color(hex: 0x2457a9), Color(hex: 0x152b58)], startPoint: .leading, endPoint: .trailing)
                    } else { JarasTheme.panel }
                }
                .overlay(alignment: .bottomLeading) {
                    if active || queued {
                        GeometryReader { geometry in
                            Rectangle().fill(active ? JarasTheme.green : JarasTheme.yellow)
                                .frame(width: geometry.size.width * (active ? progress : queueProgress), height: 2)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }.allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? color : .clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            .overlay(alignment: .leading) {
                if let expanded, let toggleDrawer {
                    Button(action: toggleDrawer) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(JarasTheme.green)
                            .frame(width: 12, height: 34).contentShape(Rectangle())
                    }.buttonStyle(.plain).jarasHelp("Show unified songs").accessibilityLabel("Show unified songs")
                        .padding(.leading, 23 + numberWidth)
                }
            }
    }
}
private func regionDurationText(_ value: Double) -> String {
    let total = max(0, Int(value.rounded()))
    if total >= 3600 {
        return String(format: "%dh %02dm %02ds", total / 3600, (total % 3600) / 60, total % 60)
    }
    if total >= 60 {
        return String(format: "%dm %02ds", total / 60, total % 60)
    }
    return "\(total)s"
}
struct SongListPreview: PreviewProvider { static var previews: some View { SongListView(show: try! AppContainer(preview: true).show).frame(height: 560) } }

#if os(macOS)
import AppKit
private struct SetlistArrowKeys: NSViewRepresentable {
    let search: () -> Bool
    let move: (Int) -> Bool
    let released: () -> Void
    let delete: () -> Void
    func makeNSView(context: Context) -> SetlistKeyView { SetlistKeyView() }
    func updateNSView(_ view: SetlistKeyView, context: Context) { view.move = move; view.search = search; view.released = released; view.delete = delete }
}
final class SetlistKeyView: NSView {
    var search: (() -> Bool)?
    var move: ((Int) -> Bool)?
    var released: (() -> Void)?
    var delete: (() -> Void)?
    private static weak var deleteOwner: SetlistKeyView?
    static func handleDelete(_ event: NSEvent) -> Bool {
        guard [51,117].contains(event.keyCode), event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty,
              let owner = deleteOwner, event.window === owner.window, owner.acceptsNavigation,
              !owner.isHiddenOrHasHiddenAncestor, owner.visibleRect.width > 0 else { return false }
        owner.stopRepeating(commit: false)
        if !event.isARepeat { owner.delete?() }
        // Consume even a protected drawer selection, so Delete cannot fall
        // through to stale selections in the grid or Track-Mixer.
        return true
    }
    func notePointerEvent(_ event: NSEvent) {
        guard event.window === window else { return }
        if visibleRect.contains(convert(event.locationInWindow, from: nil)) { Self.deleteOwner = self }
        else if Self.deleteOwner === self { Self.deleteOwner = nil }
    }
    private var monitor: Any?
    private var focusObserver: NSObjectProtocol?
    private var repeatTimer: Timer?
    private var heldKey: UInt16?
    private var acceptsNavigation: Bool {
        guard NSApp.isActive, let window, window.isKeyWindow, window.attachedSheet == nil,
              ControlMappings.shared.editing == nil else { return false }
        return !(window.firstResponder is NSTextView) && !(window.firstResponder is NSTextField) && !(window.firstResponder is NSSlider)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private func stopRepeating(commit: Bool) {
        let wasHeld = heldKey != nil
        repeatTimer?.invalidate(); repeatTimer = nil; heldKey = nil
        if commit && wasHeld { released?() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopRepeating(commit: false)
        if Self.deleteOwner === self { Self.deleteOwner = nil }
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver); self.focusObserver = nil }
        guard let window else { return }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,object: window,queue: .main) { [weak self] _ in self?.stopRepeating(commit: false) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown,.keyUp,.flagsChanged,.leftMouseDown,.rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                self.notePointerEvent(event)
                self.stopRepeating(commit: false); return event
            }
            if event.type == .keyUp {
                guard event.keyCode == self.heldKey else { return event }
                self.stopRepeating(commit: self.acceptsNavigation)
                return nil
            }
            if event.type == .flagsChanged {
                if !event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty { self.stopRepeating(commit: false) }
                return event
            }
            if ControlMappings.shared.handleKey(event) { self.stopRepeating(commit: false); return nil }
            if Self.handleDelete(event) { return nil }
            guard event.window === self.window, self.acceptsNavigation, [48,125,126].contains(event.keyCode),
                  event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty else { return event }
            if event.keyCode == 48 {
                self.stopRepeating(commit: false)
                if event.isARepeat { return nil }
                return self.search?() == true ? nil : event
            }
            // The app repeats only setlist arrows; macOS repeats are consumed so
            // each interval advances exactly one row, independent of OS settings.
            if event.isARepeat || self.heldKey == event.keyCode { return nil }
            self.stopRepeating(commit: false)
            let direction = event.keyCode == 125 ? 1 : -1
            guard self.move?(direction) == true else { return event }
            Self.deleteOwner = self
            self.heldKey = event.keyCode
            let timer = Timer(fire: Date(timeIntervalSinceNow: 0.20), interval: 0.055, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard self.heldKey != nil, self.acceptsNavigation, self.move?(direction) == true else {
                    self.stopRepeating(commit: false); return
                }
            }
            timer.tolerance = 0.004
            self.repeatTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            return nil
        }
    }
    deinit {
        repeatTimer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }
}
#endif

#if os(macOS)
private struct PlaylistSelectionClick: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> PlaylistSelectionClickView { PlaylistSelectionClickView() }
    func updateNSView(_ view: PlaylistSelectionClickView, context: Context) { view.action = action }
}
private final class PlaylistSelectionClickView: NSView {
    var action: (() -> Void)?
    override func mouseDown(with event: NSEvent) { action?() }
    override func rightMouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { action?() }
    }
}
#endif

private struct PlaylistNameShake: GeometryEffect {
    var animatableData: Double
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(animatableData * .pi * 6), y: 0))
    }
}

private struct SetlistBlockRow: View {
    let block: SetlistBlock
    var body: some View {
        HStack(spacing: 8) {
            if block.showsSymbol {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 6)); path.addLine(to: CGPoint(x: 62, y: 6))
                    path.move(to: CGPoint(x: 56, y: 0)); path.addLine(to: CGPoint(x: 62, y: 6)); path.addLine(to: CGPoint(x: 56, y: 12))
                }.stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 62, height: 12).accessibilityHidden(true)
            }
            Text(block.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .foregroundStyle(JarasTheme.green)
        }.padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 24)
            .background(Color(hex: block.color).opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: block.color).opacity(0.5)))
            .contentShape(Rectangle()).accessibilityLabel(block.name)
    }
}
private struct PlaylistRegionDrag: ViewModifier {
    let show: ShowController
    let playlist: UUID?
    let entry: UUID
    let block: Bool
    @Binding var selection: Set<UUID>
    var locked = false
    @State private var targeted = false
    private var scope: String { (show.current?.id.uuidString ?? "") + ":" + (playlist?.uuidString ?? "all") }
    @ViewBuilder func body(content: Content) -> some View {
        if locked { content.modifier(LockedRegionDrag()) }
        else {
        draggable(content)
            .onDrop(of: [UTType.text], isTargeted: $targeted) { providers, location in
                guard let provider = providers.first else { return false }
                let after = location.y >= (block ? 12 : 17)
                let expectedScope = scope
                _ = provider.loadObject(ofClass: String.self) { value, _ in
                    guard let value else { return }
                    let parts = value.split(separator: ":")
                    guard parts.count == 4, parts[0] == "jaras-setlist",
                          String(parts[1]) + ":" + String(parts[2]) == expectedScope else { return }
                    let ids = Set(parts[3].split(separator: ",").compactMap { UUID(uuidString: String($0)) })
                    Task { @MainActor in
                        guard scope == expectedScope else { return }
                        show.moveSetlistEntries(ids, relativeTo: entry, after: after)
                    }
                }
                return true
            }
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(targeted ? JarasTheme.green : .clear, lineWidth: 2).allowsHitTesting(false))
        }
    }
    @ViewBuilder private func draggable(_ content: Content) -> some View {
        if block || playlist != nil {
            content.onDrag {
                if !selection.contains(entry) { selection = [entry] }
                let ids = show.setlistEntries.filter {
                    guard selection.contains($0.id) else { return false }
                    if playlist == nil, case .region = $0 { return false }
                    return true
                }.map { $0.id.uuidString }.joined(separator: ",")
                return NSItemProvider(object: ("jaras-setlist:" + scope + ":" + ids) as NSString)
            }
        } else { content }
    }
}
private struct LockedRegionDrag: ViewModifier {
    @State private var shake = 0.0
    @State private var dragging = false
    @State private var warning = false
    @State private var dismissal: Task<Void, Never>?
    func body(content: Content) -> some View {
        content.modifier(InputValidationShake(animatableData: shake))
            .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in
                guard !dragging else { return }
                dragging = true; warning = true
                withAnimation(.linear(duration: 0.3)) { shake += 1 }
                dismissal?.cancel()
                dismissal = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
                    warning = false
                }
            }.onEnded { _ in dragging = false })
            .overlay(alignment: .top) {
                if warning {
                    Text("Not possible").font(.caption).foregroundStyle(.white)
                        .padding(6).background(Color.red.opacity(0.9)).clipShape(RoundedRectangle(cornerRadius: 4))
                        .allowsHitTesting(false)
                }
            }
            .onDisappear { dismissal?.cancel() }
    }
}

private struct RegionStopButton: View {
    let active: Bool
    let action: () -> Void
    @State private var dimmed = false
    var body: some View {
        Button(action: action) {
            Text("STOP").font(.system(size: 9, weight: .bold))
                .foregroundStyle(active ? JarasTheme.green : Color.red)
                .padding(.horizontal, 6).frame(height: 26)
                .background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(active ? JarasTheme.green : .red, lineWidth: 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).opacity(active && dimmed ? 0.4 : 1)
            .jarasHelp("Stop automatically at the end of each region").accessibilityLabel("Region stop")
            .onAppear { animate() }.onChange(of: active) { _ in animate() }
    }
    private func animate() {
        withAnimation(nil) { dimmed = false }
        if active { withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { dimmed = true } }
    }
}

#if os(macOS)
/// AppKit may restore the scroller while SwiftUI updates a ScrollView. Suppress
/// it during layout, without polling or leaving a reserved strip beside songs.
private struct SetlistScrollbarsHidden: NSViewRepresentable {
    func makeNSView(context: Context) -> SetlistScrollbarSuppressionView { SetlistScrollbarSuppressionView() }
    func updateNSView(_ view: SetlistScrollbarSuppressionView, context: Context) { view.suppressScrollbars() }
}
private final class SetlistScrollbarSuppressionView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        suppressScrollbars()
        DispatchQueue.main.async { [weak self] in self?.suppressScrollbars() }
    }
    override func layout() { super.layout(); suppressScrollbars() }
    func suppressScrollbars() {
        guard let scroll = enclosingScrollView else { return }
        if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
        if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
        if scroll.verticalScroller != nil { scroll.verticalScroller = nil }
        if scroll.horizontalScroller != nil { scroll.horizontalScroller = nil }
    }
}
#endif
