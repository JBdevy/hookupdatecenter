import SwiftUI
import UniformTypeIdentifiers
import Combine
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
    struct Content {
        let entries: [SetlistEntry]
        let unifiedRegionIDs: Set<UUID>
        var regionIDs: [UUID: Int] = [:]
    }
    private var key: Key?
    private var cached = Content(entries: [], unifiedRegionIDs: [])
    func content(for key: Key, build: () -> Content) -> Content {
        if self.key == key { return cached }
        cached = build(); self.key = key
        return cached
    }
}
struct SongListView: View {
    #if os(macOS)
    let show: ShowController
    @StateObject private var updates: ShowPresentationObserver
    var sidebarScrollController: SidebarScrollController? = nil
    init(show: ShowController, sidebarScrollController: SidebarScrollController? = nil) {
        self.show = show; self.sidebarScrollController = sidebarScrollController
        _updates = StateObject(wrappedValue: show.presentationObserver)
    }
    #else
    @ObservedObject var show: ShowController
    #endif
    private struct EntryEdit: Identifiable { let id: UUID; let name: String; let color: UInt32; let block: Bool; var regionTargets: Set<UUID> = [] }
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
    @State private var multiLoopRegion: Part?
    @AppStorage("jaras.setlist.idMode") private var idMode = "playlist"
    @AppStorage("jaras.setlist.fontStyle") private var fontStyle = 0
    @ObservedObject private var allRegionsTextColor = AppearanceColor.shared("jaras.setlist.allRegionsTextColor", default: 0xffffff)
    @ObservedObject private var playlistTextColor = AppearanceColor.shared("jaras.setlist.playlistTextColor", default: 0x00ff9a)
    @ObservedObject private var unifiedTextColor = AppearanceColor.shared("jaras.setlist.unifiedTextColor", default: 0xffeb3b)
    @AppStorage("jaras.blocks.symbol") private var defaultBlockSymbol = true
    @State private var blockSymbolTargets = Set<UUID>()
    @State private var editingMultipleSymbols = false
    @State private var multipleSymbolDraft = true
    @State private var editingBlockSymbol = true
    @State private var editingUppercaseName = true
    @State private var showingBlockDefaults = false
    @State private var blockSymbolDraft = true
    @State private var createdBlock: UUID?
    @State private var selectedEntries: Set<UUID> = []
    @State private var entrySelectionAnchor: UUID?
    @State private var playlistMaximumListHeight: CGFloat = 500
    @State private var choosingPlaylist = false
    @State private var creatingPlaylist = false
    @State private var addingToPlaylist: UUID?
    private var playlistCandidates: [Part] {
        guard let id = addingToPlaylist, let playlist = show.regionSetlist.playlists.first(where: { $0.id == id }) else { return show.allRegions }
        let existing = Set(playlist.regionIds)
        return show.allRegions.filter { !existing.contains($0.id) }
    }
    @State private var showingAutoOptions = false
    @State private var searching = false
    @State private var query = ""
    @State private var playlistName = ""
    @State private var missingPlaylistName = false
    @State private var nameShake = 0.0
    @FocusState private var playlistNameFocused: Bool
    @State private var selection: [UUID] = []
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
        show.selectSetlistBlock(selectedEntries.count == 1 ? selectedEntries.first : nil)
    }
    var body: some View {
        let song = show.current
        let playlist = show.selectedRegionPlaylist
        let setlist = show.regionSetlist
        let content = entryCache.content(for: SetlistEntryCache.Key(controller: ObjectIdentifier(show), project: show.snapshot.project.id, projectRevision: show.projectRevision, setlistRevision: show.setlistRevision, song: song?.id, playlist: setlist.selectedId, expanded: expandedRegions)) {
            let children = Dictionary(grouping: (song?.parts ?? []).filter { $0.parentRegionID != nil }, by: { $0.parentRegionID! })
            let entries = show.setlistEntries.flatMap { entry -> [SetlistEntry] in
                guard expandedRegions.contains(entry.id) else { return [entry] }
                let nested = (children[entry.id] ?? []).sorted { $0.startTime == $1.startTime ? $0.endTime < $1.endTime : $0.startTime < $1.startTime }
                return [entry] + nested.enumerated().map { .region($0.element, number: $0.offset + 1) }
            }
            return SetlistEntryCache.Content(entries: entries, unifiedRegionIDs: Set(children.keys), regionIDs: Dictionary(uniqueKeysWithValues: (song?.parts ?? []).enumerated().map { ($0.element.id, $0.offset + 1) }))
        }
        let regionIDs = content.regionIDs
        let visible = content.entries
        let transport = show.snapshot.transport
        let playing = transport.playing ? song?.parts.first(where: { $0.id == transport.regionId }) : nil
        let playingBounds = playing?.parentRegionID.flatMap { parent in song?.parts.first(where: { $0.id == parent }) } ?? playing
        let ignoredRegion = transport.ignoreNextRegionId.flatMap { id in song?.parts.first { $0.id == id } }
        let displayedPlaying = transport.playing ? song?.playingSetlistRegion(ignoredRegion?.id ?? transport.regionId, position: ignoredRegion?.startTime ?? transport.position, expanded: expandedRegions) : nil
        let playbackEnd = transport.ignoreNextEnd ?? playingBounds?.endTime ?? transport.position
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Button { choosingPlaylist.toggle() } label: {
                    HStack(spacing: 3) {
                        Group { if let playlist { Text(playlist.name) } else { Text("All regions") } }.lineLimit(1)
                        Spacer(minLength: 3)
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }.font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 7).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.45)))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).jarasHelp("Choose playlist")
                    #if os(macOS)
                    .background(PlaylistPopoverSpaceReader { height in
                        if abs(playlistMaximumListHeight - height) > 0.5 { playlistMaximumListHeight = height }
                    })
                    #endif
                    .popover(isPresented: $choosingPlaylist, arrowEdge: .bottom) {
                        PlaylistSelectionPanel(show: show, isPresented: $choosingPlaylist, maximumListHeight: $playlistMaximumListHeight, addRegions: { id in
                            addingToPlaylist = id
                            playlistName = show.regionSetlist.playlists.first { $0.id == id }?.name ?? ""
                            missingPlaylistName = false; selection = []; selectionAnchor = nil
                            choosingPlaylist = false; creatingPlaylist = true
                        }) { query = "" }
                    }
                Button {
                    addingToPlaylist = nil; playlistName = ""; missingPlaylistName = false; nameShake = 0; selection = []; selectionAnchor = nil
                    choosingPlaylist = false; creatingPlaylist = true
                } label: { Image(systemName: "plus").frame(width: 27, height: 30).contentShape(Rectangle()) }
                    .buttonStyle(.plain).jarasHelp("Create playlist").accessibilityLabel("Create playlist")
                Button { searching.toggle() } label: {
                    Image(systemName: "magnifyingglass").foregroundStyle(query.isEmpty ? .white : JarasTheme.green)
                        .frame(width: 27, height: 30).contentShape(Rectangle())
                }.buttonStyle(.plain).jarasHelp("Search songs (Tab)").accessibilityLabel("Search songs")
                    .popover(isPresented: $searching, attachmentAnchor: .rect(.bounds), arrowEdge: .top) { searchPanel }
                Button { show.toggleRegionAuto() } label: {
                    Text("AUTO").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(setlist.autoAdvance ? .black : JarasTheme.secondary)
                        .frame(width: 34, height: 26)
                        .background(setlist.autoAdvance ? JarasTheme.green : JarasTheme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 4)).contentShape(Rectangle())
                }.buttonStyle(.plain).jarasHelp("Queue the next song automatically")
                    .immediateRightClick { showingAutoOptions = true }
                    .popover(isPresented: $showingAutoOptions) {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("Without playback", isOn: Binding(get: { show.regionSetlist.preparesWithoutPlayback }, set: { show.setPrepareWithoutPlayback($0) }))
                            if !show.regionSetlist.preparesWithoutPlayback {
                                Toggle("Automatic Subplay", isOn: Binding(get: { show.regionSetlist.automaticSubplay == true }, set: { show.setAutomaticSubplay($0) }))
                                Picker("Start before the end", selection: Binding(get: { Int(show.regionSetlist.subplayLeadTime) }, set: { show.setAutomaticSubplay(show.regionSetlist.automaticSubplay == true, seconds: Double($0)) })) {
                                    ForEach(1...5, id: \.self) { Text("\($0)s").tag($0) }
                                }.disabled(show.regionSetlist.automaticSubplay != true)
                            }
                        }.toggleStyle(.automatic).padding(18).frame(width: 270)
                    }
                Button { createdBlock = show.addSetlistBlock(symbol: defaultBlockSymbol, namePrefix: JarasLocalization.string("Bloco")) } label: {
                    Text("Blocks").font(.system(size: 9, weight: .bold)).padding(.horizontal, 6).frame(height: 26)
                        .background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 4)).contentShape(Rectangle())
                }.buttonStyle(.plain).jarasHelp("Add a setlist block").accessibilityLabel("Blocks")
                    .immediateRightClick {
                        guard show.selectedRegionPlaylist != nil else { return }
                        blockSymbolDraft = defaultBlockSymbol; showingBlockDefaults = true
                    }
                    .disabled(playlist == nil)
                    .opacity(playlist == nil ? 0.4 : 1)
                RegionStopButton(active: setlist.stopsAtRegionEnd) { show.toggleRegionStop() }
            }.padding(.horizontal, 8).padding(.bottom, 6)
            ScrollViewReader { scroll in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(visible) { entry in
                            switch entry {
                            case .block(let block):
                                SetlistBlockRow(block: block, fontStyle: fontStyle, selected: selectedEntries.contains(block.id))
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(selectedEntries.contains(block.id) ? JarasTheme.green : .clear, lineWidth: 1))
                                    .onTapGesture { selectEntry(block.id, visible: visible) }
                                    .immediateRightClick {
                                        let blocks = show.listedBlocks.filter { selectedEntries.contains($0.id) }
                                        if selectedEntries.contains(block.id), blocks.count > 1, blocks.count == selectedEntries.count {
                                            blockSymbolTargets = Set(blocks.map(\.id))
                                            multipleSymbolDraft = blocks.allSatisfy(\.showsSymbol)
                                            editingMultipleSymbols = true
                                        } else { editingBlockSymbol = block.showsSymbol; editingEntry = EntryEdit(id: block.id, name: block.name, color: block.color, block: true) }
                                    }
                                    .modifier(PlaylistRegionDrag(show: show, playlist: playlist?.id, entry: block.id, block: true, selection: $selectedEntries, name: block.name))
                                    .id(block.id)
                            case .region(let region, let number):
                            let active = displayedPlaying?.id == region.id
                            let queued = transport.playing && transport.queuedRegionId == region.id
                            let regionEnd = active && ignoredRegion != nil ? playbackEnd : region.endTime
                            let duration = max(0.001, regionEnd - region.startTime)
                            let remaining = active ? max(0, regionEnd - transport.position) : duration
                            let progress = active ? min(1, max(0, (transport.position - region.startTime) / duration)) : 0
                            let queueRemaining = queued ? max(0, playbackEnd - transport.position) : 0
                            let queueLength = max(0.001, playbackEnd - (transport.queueStartedAt ?? transport.position))
                            RegionSetlistRow(region: region, fontStyle: fontStyle, nameColor: UInt32(region.parentRegionID != nil ? unifiedTextColor.value : playlist == nil ? allRegionsTextColor.value : playlistTextColor.value), number: idMode == "region" ? (regionIDs[region.id] ?? number) : number, selected: selectedEntries.contains(region.id),
                                             active: active, queued: queued, prepareOnly: setlist.preparesWithoutPlayback, remaining: Int(ceil(remaining)),
                                             progress: progress, queueProgress: queued ? min(1, queueRemaining / queueLength) : 0,
                                             playback: SetlistPlaybackBinding(show: show, region: region, end: regionEnd, playbackEnd: playbackEnd),
                                             expanded: content.unifiedRegionIDs.contains(region.id) ? expandedRegions.contains(region.id) : nil,
                                             toggleDrawer: {
                                                 if !expandedRegions.insert(region.id).inserted { expandedRegions.remove(region.id) }
                                             }) {
                                selectEntry(region.id, visible: visible)
                            }.equatable().padding(.leading, region.parentRegionID == nil ? 0 : 18)
                                .contextMenu {
                                    let targets = selectedEntries.contains(region.id) ? selectedEntries : [region.id]
                                    if targets.count == 1 && !content.unifiedRegionIDs.contains(region.id) { Button("Multiloops") { multiLoopRegion = region } }
                                    Button("Detect BPM…") { show.detectBPMRegions = visible.compactMap { entry in
                                        if case .region(let part, _) = entry, targets.contains(part.id) { return part.id }; return nil
                                    } }
                                    Button("Edit song") { editingUppercaseName = region.usesUppercase; editingEntry = EntryEdit(id: region.id, name: region.name, color: region.color ?? 0x705264, block: false, regionTargets: targets) }
                                    if region.parentRegionID == nil {
                                    Button(playlist == nil ? "Delete region" : "Remove from playlist", role: .destructive) {
                                        requestRemoval([region.id], keyboard: false)
                                    }
                                    }
                                }
                                .modifier(PlaylistRegionDrag(show: show, playlist: playlist?.id, entry: region.id, block: false, selection: $selectedEntries, locked: region.parentRegionID != nil, name: region.name))
                                .id(region.id)
                            }
                        }
                        if visible.isEmpty {
                            Text("Select an item and press Shift + R to create a region.")
                                .font(.caption).foregroundStyle(JarasTheme.secondary).padding(12)
                        }
                    }.padding(.leading, 8)
                    // Keep the drawer button inside the scroll viewport.
                    .padding(.trailing, 2)
                    #if os(macOS)
                    .background(SetlistScrollbarsHidden())
                    .background {
                        if let sidebarScrollController { SidebarScrollProbe(controller: sidebarScrollController) }
                    }
                    #endif
                }.onChange(of: show.focusedRegion) { id in
                    if let id, let parent = show.current?.parts.first(where: { $0.id == id })?.parentRegionID { expandedRegions.insert(parent) }
                    if let id { selectedEntries = [id]; entrySelectionAnchor = id; scroll.scrollTo(id) }
                    else { selectedEntries = []; entrySelectionAnchor = nil }
                }
                    .onChange(of: selectedEntries) { ids in
                        AudioExportSelection.shared.setRegions(ids, song: show.current?.id)
                    }
                    .onChange(of: show.selectedRegionPlaylist?.id) { _ in selectedEntries = []; entrySelectionAnchor = nil }
                    .onChange(of: show.snapshot.project.id) { _ in selectedEntries = []; entrySelectionAnchor = nil; creatingPlaylist = false; addingToPlaylist = nil }
                    .onChange(of: show.regionFocusRequest) { request in
                        // Apply after the destination playlist has laid out, including repeated results.
                        DispatchQueue.main.async {
                            guard show.regionFocusRequest == request, let id = show.focusedRegion else { return }
                            if let parent = show.current?.parts.first(where: { $0.id == id })?.parentRegionID { expandedRegions.insert(parent) }
                            selectedEntries = [id]; entrySelectionAnchor = id
                            scroll.scrollTo(id)
                        }
                    }
                    .onChange(of: show.setlistFocusRequest) { request in
                        DispatchQueue.main.async {
                            guard show.setlistFocusRequest == request, let id = show.focusedRegion else { return }
                            if let parent = show.current?.parts.first(where: { $0.id == id })?.parentRegionID { expandedRegions.insert(parent) }
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
        }, playlist: { direction in
            guard !creatingPlaylist && !choosingPlaylist else { return nil }
            let lists = show.regionSetlist.playlists.filter { $0.songId == show.current?.id }
            guard !lists.isEmpty else { return nil }
            let current = lists.firstIndex { $0.id == show.regionSetlist.selectedId }
            let next = current.map { ($0 + direction + lists.count) % lists.count } ?? (direction > 0 ? 0 : lists.count - 1)
            show.selectRegionPlaylist(lists[next].id); query = ""
            return lists[next].name
        }, released: { show.finishRegionNavigation() }, delete: { requestRemoval(selectedEntries, keyboard: true) }))
        #endif
        .onChange(of: show.setlistNavigationRequest) { request in
            guard let request, !creatingPlaylist && !choosingPlaylist else { return }
            show.stepRegion(request.direction, entries: visible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(hex: 0x151b22))
        .alert(Text(verbatim: confirmingRemoval ? JarasLocalization.string(removal?.playlist == nil ? "Delete selected regions from the project?" : "Remove selected items from this playlist?") : ""), isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) { removal = nil }
            Button(removal?.playlist == nil ? "Delete" : "Remove from playlist", role: .destructive) {
                if let removal, removal.project == show.snapshot.project.id, removal.song == show.current?.id,
                   removal.playlist == show.selectedRegionPlaylist?.id, show.deleteSetlistEntries(removal.ids) {
                    selectedEntries.subtract(removal.ids)
                    expandedRegions.subtract(removal.ids)
                    if let entrySelectionAnchor, removal.ids.contains(entrySelectionAnchor) { self.entrySelectionAnchor = nil }
                }
                removal = nil
            }
        } message: {
            if removal?.playlist == nil {
                Text("The selected regions, their items and markers will be removed from the timeline. Media files will remain in the project folder.")
            }
        }
        .sheet(item: $multiLoopRegion) { region in MultiLoopsEditor(show: show, regionID: region.id) }
        .sheet(item: $editingEntry) { edit in
            NameColorEditor(title: edit.block ? "Edit block" : "Edit song", initialName: edit.name, initialColor: edit.color, save: { name, color in
                if edit.block { show.editSetlistBlock(edit.id, name: name, color: color, symbol: editingBlockSymbol) }
                else if edit.regionTargets.count > 1 { show.editRegionColors(edit.regionTargets, color: color) }
                else { show.editRegion(edit.id, name: name, color: color, uppercaseName: editingUppercaseName) }
            }, symbol: edit.block ? $editingBlockSymbol : nil, uppercaseName: edit.block || edit.regionTargets.count > 1 ? nil : $editingUppercaseName, nameEditable: edit.regionTargets.count <= 1, showsName: edit.regionTargets.count <= 1).background(JarasTheme.panel)
        }
        .sheet(isPresented: $editingMultipleSymbols) {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("SIMBOL", isOn: $multipleSymbolDraft)
                    .onChange(of: multipleSymbolDraft) { enabled in show.setBlockSymbols(blockSymbolTargets, enabled: enabled) }
                HStack { Spacer(); Button("Close") { editingMultipleSymbols = false }.keyboardShortcut(.cancelAction) }
            }.padding(18).frame(width: 240).background(JarasTheme.panel)
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
        let results = show.searchRegions(query, byRegionID: idMode == "region")
        let ids = Dictionary(uniqueKeysWithValues: (show.current?.parts ?? []).enumerated().map { ($0.element.id, $0.offset + 1) })
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
                                if idMode == "region", let number = ids[region.id] { Text(String(format: "%02d", number)).monospacedDigit().foregroundStyle(JarasTheme.secondary) }
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
            }.frame(height: 300) // Keep the popover anchored while filtering results.
        }.padding(12).frame(width: 300).onAppear { searchFocused = true }
        #if os(iOS)
        .background(RemoteKeyboardDismissal(active: searchFocused) { searchFocused = false })
        #endif
    }
    private var creationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(addingToPlaylist == nil ? "New playlist" : "Add regions").font(.system(size: 13, weight: .semibold)); Spacer()
                Button { creatingPlaylist = false } label: { Image(systemName: "xmark").frame(width: 30, height: 30).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Cancel playlist creation")
            }
            TextField("Playlist name", text: $playlistName).textFieldStyle(.roundedBorder).disabled(addingToPlaylist != nil)
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
                    selection = playlistCandidates.map(\.id)
                    selectionAnchor = playlistCandidates.first?.id
                }
                Button("Clear") { selection.removeAll(); selectionAnchor = nil }
                Spacer(minLength: 0)
            }.buttonStyle(StageButtonStyle()).controlSize(.small)
            Text("⌘ / Ctrl: multiple · Shift: range").font(.system(size: 9)).foregroundStyle(JarasTheme.secondary)
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 3) {
                    ForEach(playlistCandidates) { region in
                        Button { selectForPlaylist(region.id) } label: {
                            HStack(spacing: 5) {
                                if let order = selection.firstIndex(of: region.id) {
                                    Text("\(order + 1)").monospacedDigit().foregroundStyle(JarasTheme.green)
                                        .frame(minWidth: 18)
                                }
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
                Button(addingToPlaylist == nil ? "Create" : "Add regions", action: createPlaylist)
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
        let applied = addingToPlaylist.map { show.addRegionsToPlaylist($0, selected: selection) }
            ?? show.createRegionPlaylist(name: playlistName, selected: selection)
        if applied {
            creatingPlaylist = false; query = ""
        }
    }
    private func selectForPlaylist(_ id: UUID) {
        let ids = playlistCandidates.map(\.id)
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor = selectionAnchor,
           let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: id) {
            let range = a <= b ? Array(ids[a...b]) : Array(ids[b...a].reversed())
            selection = flags.contains(.command) || flags.contains(.control)
                ? selection + range.filter { !selection.contains($0) } : range
            return
        }
        if flags.contains(.command) || flags.contains(.control) {
            if selection.contains(id) { selection.removeAll { $0 == id } } else { selection.append(id) }
        } else { selection = [id] }
        #else
        if selection.contains(id) { selection.removeAll { $0 == id } } else { selection.append(id) }
        #endif
        selectionAnchor = id
    }
}
private struct PlaylistNameEditor: View {
    let save: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var invalid = false
    @State private var shake = 0.0
    @FocusState private var focused: Bool
    init(initialName: String, save: @escaping (String) -> Bool) {
        self.save = save; _name = State(initialValue: initialName)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit playlist").font(.headline)
            TextField("Playlist name", text: $name).focused($focused)
                .onSubmit(confirm)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(invalid ? Color.red : Color.clear))
                .modifier(InputValidationShake(animatableData: shake))
                .onChange(of: name) { _ in invalid = false }
            if invalid { Text("Choose a name").font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: confirm).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 320).onAppear { focused = true }
    }
    private func confirm() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            invalid = true; focused = true
            withAnimation(.linear(duration: 0.3)) { shake += 1 }
            return
        }
        if save(trimmed) { dismiss() }
    }
}
// The popover is a separate presentation root: observe the controller here so
// cloning/deleting updates its rows without dismissing and reopening it.
private struct PlaylistSelectionPanel: View {
    @ObservedObject var show: ShowController
    @Binding var isPresented: Bool
    @Binding var maximumListHeight: CGFloat
    var addRegions: (UUID) -> Void
    var didSelect: () -> Void
    @State private var editingPlaylist: RegionPlaylist?
    @State private var deletingPlaylist: UUID?
    @State private var confirmingPlaylistDelete = false
    private let rowHeight: CGFloat = 32
    private let rowSpacing: CGFloat = 3
    var body: some View {
        let playlists = show.regionSetlist.playlists.filter { $0.songId == show.current?.id }
        let contentHeight = CGFloat(playlists.count + 1) * rowHeight + CGFloat(playlists.count) * rowSpacing
        let needsScroll = contentHeight > maximumListHeight
        VStack(spacing: 2) {
            HStack {
                Text("Playlists").font(.headline); Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark").frame(width: 30, height: 30).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Close playlists")
            }
            ScrollView(showsIndicators: needsScroll) {
                VStack(spacing: rowSpacing) {
                    playlistChoice("All regions", id: nil)
                    ForEach(playlists) { list in playlistChoice(list.name, id: list.id) }
                }
                #if os(macOS)
                .background(PlaylistPersistentScrollbar(visible: needsScroll))
                #endif
            }
            .jarasScrollDisabled(!needsScroll)
            .frame(height: min(contentHeight, maximumListHeight))
        }.padding(10).background(JarasTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(JarasTheme.line))
            .frame(width: 240)
            .sheet(item: $editingPlaylist) { playlist in
                PlaylistNameEditor(initialName: playlist.name) { name in
                    show.renameRegionPlaylist(playlist.id, name: name)
                }
            }
            .alert("Delete playlist?", isPresented: $confirmingPlaylistDelete) {
                Button("Delete playlist", role: .destructive) {
                    if let id = deletingPlaylist { show.deleteRegionPlaylist(id) }
                    deletingPlaylist = nil
                }
                Button("Cancel", role: .cancel) { deletingPlaylist = nil }
            }
    }
    private func playlistChoice(_ name: String, id: UUID?) -> some View {
        Button {
            show.selectRegionPlaylist(id); isPresented = false; didSelect()
        } label: {
            HStack {
                Group { if id == nil { Text(LocalizedStringKey(name)) } else { Text(name) } }.lineLimit(1); Spacer()
                if show.regionSetlist.selectedId == id { Image(systemName: "checkmark").foregroundStyle(JarasTheme.green) }
            }.font(.system(size: 12)).padding(.horizontal, 8)
                .frame(maxWidth: .infinity).frame(height: rowHeight)
                .background(JarasTheme.background).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .contextMenu {
                if let id {
                    Button("Add regions") { addRegions(id) }
                    Button("Edit") { editingPlaylist = show.regionSetlist.playlists.first { $0.id == id } }
                    Button("Clone playlist") { show.cloneRegionPlaylist(id) }
                    Button("Delete playlist", role: .destructive) { deletingPlaylist = id; confirmingPlaylistDelete = true }
                }
            }
    }
}
#if os(macOS)
// A legacy scroller remains visible while idle, including when the system
// preference normally hides scrollbars. Its full native hit area stays usable.
private struct PlaylistPersistentScrollbar: NSViewRepresentable {
    var visible: Bool
    func makeNSView(context: Context) -> PlaylistScrollbarView {
        let view = PlaylistScrollbarView(); view.visible = visible; return view
    }
    func updateNSView(_ view: PlaylistScrollbarView, context: Context) {
        view.visible = visible; view.configure()
        DispatchQueue.main.async { [weak view] in view?.configure() }
    }
}
private final class PlaylistGreenScroller: NSScroller {
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        NSColor(white: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 3, y: slotRect.minY, width: 6, height: slotRect.height), xRadius: 3, yRadius: 3).fill()
    }
    override func drawKnob() {
        NSColor(calibratedRed: 84.0 / 255, green: 1, blue: 147.0 / 255, alpha: 1).setFill()
        let knob = rect(for: .knob)
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 3, y: knob.minY, width: 6, height: knob.height), xRadius: 3, yRadius: 3).fill()
    }
}
private final class PlaylistScrollbarView: NSView {
    var visible = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); configure()
        DispatchQueue.main.async { [weak self] in self?.configure() }
    }
    override func layout() { super.layout(); configure() }
    func configure() {
        guard let scroll = enclosingScrollView else { return }
        if scroll.scrollerStyle != .legacy { scroll.scrollerStyle = .legacy }
        if scroll.autohidesScrollers { scroll.autohidesScrollers = false }
        if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
        if visible && !(scroll.verticalScroller is PlaylistGreenScroller) {
            scroll.verticalScroller = PlaylistGreenScroller(frame: NSRect(x: 0, y: 0, width: 14, height: 100))
        }
        if scroll.hasVerticalScroller != visible { scroll.hasVerticalScroller = visible }
    }
}
// Measure from the actual chooser button on its own monitor, reserving space
// for the popover arrow, title and padding. No fixed seven-row scroll limit.
private struct PlaylistPopoverSpaceReader: NSViewRepresentable {
    var changed: (CGFloat) -> Void
    func makeNSView(context: Context) -> PlaylistPopoverAnchorView {
        let view = PlaylistPopoverAnchorView(); view.changed = changed; return view
    }
    func updateNSView(_ view: PlaylistPopoverAnchorView, context: Context) {
        view.changed = changed; view.measure()
    }
}
private final class PlaylistPopoverAnchorView: NSView {
    var changed: ((CGFloat) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var lastHeight: CGFloat = 0
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let window {
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.measure() })
            }
        }
        measure()
    }
    override func layout() { super.layout(); measure() }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); measure() }
    override func setFrameOrigin(_ point: NSPoint) { super.setFrameOrigin(point); measure() }
    func measure() {
        guard let window, let screen = window.screen, bounds.height > 0 else { return }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let visible = screen.visibleFrame
        let space = max(anchor.minY - visible.minY, visible.maxY - anchor.maxY)
        let height = max(96, min(space, visible.height) - 68)
        guard abs(lastHeight - height) > 0.5 else { return }
        lastHeight = height
        DispatchQueue.main.async { [weak self] in self?.changed?(height) }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}
#endif
private struct SetlistPlaybackBinding: Equatable {
    let show: ShowController
    let region: Part
    let end: Double
    let playbackEnd: Double
    static func == (a: Self, b: Self) -> Bool {
        a.show === b.show && a.region == b.region && a.end == b.end && a.playbackEnd == b.playbackEnd
    }
}
private struct RegionSetlistRow: View, Equatable {
    let region: Part
    var fontStyle: Int = 0
    var nameColor: UInt32 = 0xffffff
    let number: Int
    let selected: Bool
    let active: Bool
    let queued: Bool
    let prepareOnly: Bool
    let remaining: Int
    let progress: Double
    let queueProgress: Double
    var playback: SetlistPlaybackBinding? = nil
    var expanded: Bool? = nil
    var toggleDrawer: (() -> Void)? = nil
    let select: () -> Void
    static func == (a: Self, b: Self) -> Bool {
        a.region == b.region && a.fontStyle == b.fontStyle && a.nameColor == b.nameColor && a.number == b.number && a.selected == b.selected &&
        a.active == b.active && a.queued == b.queued && a.prepareOnly == b.prepareOnly && a.remaining == b.remaining &&
        a.progress == b.progress && a.queueProgress == b.queueProgress && a.playback == b.playback && a.expanded == b.expanded
    }
    var body: some View {
        let color = Color(hex: region.color ?? 0x705264)
        let numberWidth = CGFloat(max(2, String(number).count)) * 6
        Button(action: select) {
            #if os(macOS)
            NativeRegionSetlistLabel(number: number, name: region.displayName, duration: regionDurationText(Double(remaining)),
                color: region.color ?? 0x705264, selected: selected, active: active, queued: queued, prepareOnly: prepareOnly,
                progress: progress, queueProgress: queueProgress, fontStyle: fontStyle, nameColor: nameColor, playback: active || queued ? playback : nil)
                .frame(height: 34).frame(maxWidth: .infinity).contentShape(Rectangle())
            #else
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(active ? Color.red : queued ? (prepareOnly ? JarasTheme.green : .orange) : color).frame(width: 3)
                Text(String(format: "%02d", number)).font(.system(size: 9, design: .monospaced)).foregroundStyle(JarasTheme.secondary)
                    .frame(width: numberWidth, alignment: .leading)
                Text(region.displayName).font(fontStyle == 2 ? .system(size: 13, weight: .bold).italic() : .system(size: 13, weight: fontStyle == 0 ? .regular : .bold)).foregroundStyle(Color(hex: nameColor)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
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
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected && !active && !queued ? JarasTheme.green : .clear, lineWidth: 1.5))
                .contentShape(Rectangle())
            #endif
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel(Text(verbatim: String(format: "%02d", number) + ", " + region.displayName + ", " + regionDurationText(Double(remaining))))
            .frame(maxWidth: .infinity)
            .padding(.trailing, 14)
            .overlay(alignment: .trailing) {
            Group {
                if let expanded, let toggleDrawer {
                    Button(action: toggleDrawer) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(JarasTheme.green)
                            .frame(width: 14, height: 34).contentShape(Rectangle())
                    }.buttonStyle(.plain).jarasHelp("Show unified songs").accessibilityLabel("Show unified songs")
                } else {
                    Color.clear.frame(width: 14, height: 34).allowsHitTesting(false)
                }
            }.frame(width: 14, height: 34).fixedSize()
        }
    }
}
#if os(macOS)
import AppKit
import CoreText

/// The native label keeps text shaping and drawing local while the surrounding
/// SwiftUI Button continues to own selection, menus and drag interactions.
private struct NativeRegionSetlistLabel: NSViewRepresentable {
    let number: Int
    let name: String
    let duration: String
    let color: UInt32
    let selected: Bool
    let active: Bool
    let queued: Bool
    let prepareOnly: Bool
    let progress: Double
    let queueProgress: Double
    var fontStyle: Int = 0
    var nameColor: UInt32 = 0xffffff
    var playback: SetlistPlaybackBinding? = nil
    func makeNSView(context: Context) -> NativeRegionSetlistLabelView { NativeRegionSetlistLabelView() }
    func updateNSView(_ view: NativeRegionSetlistLabelView, context: Context) {
        view.configure(number: number, name: name, duration: duration, color: color, selected: selected,
                       active: active, queued: queued, prepareOnly: prepareOnly, progress: progress, queueProgress: queueProgress, fontStyle: fontStyle, nameColor: nameColor)
        view.bindPlayback(playback)
    }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeRegionSetlistLabelView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: 34)
    }
}
private final class NativeRegionSetlistLabelView: NSView {
    private static let nameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let numberFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    private static let durationFont: NSFont = {
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType, .selectorIdentifier: kMonospacedNumbersSelector]]])
        return NSFont(descriptor: descriptor, size: 9) ?? font
    }()
    private static let green = NSColor(JarasTheme.green).cgColor
    private static let yellow = NSColor(JarasTheme.yellow).cgColor
    private static let panel = NSColor(JarasTheme.panel).cgColor
    private static let red = NSColor(Color.red).cgColor
    private static let orange = NSColor(Color.orange).cgColor
    private static let secondary = NSColor(JarasTheme.secondary)
    private static let gradients: [CGGradient] = [(0x8b2026,0x4c171c),(0x19633a,0x123b27),(0xa84b13,0x572808),(0x2457a9,0x152b58)].map {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                   colors: [NSColor(Color(hex: UInt32($0.0))).cgColor, NSColor(Color(hex: UInt32($0.1))).cgColor] as CFArray,
                   locations: [0,1])!
    }
    private var ellipsis = NativeRegionSetlistLabelView.line("…", font: NativeRegionSetlistLabelView.nameFont)
    private var nameColorValue: UInt32 = 0xffffff
    private var fontStyleValue = -1
    private var numberText = "", nameText = "", durationText = ""
    private var numberLine: CTLine?, nameLine: CTLine?, durationLine: CTLine?
    private var nameWidth: CGFloat = 0, durationWidth: CGFloat = 0, numberWidth: CGFloat = 12
    private var truncatedName: CTLine?
    private var truncationWidth: CGFloat = -1
    private var colorValue: UInt32?
    private var stripe = NSColor.clear.cgColor
    private var selected = false, active = false, queued = false, prepareOnly = false
    private var progress = 0.0, queueProgress = 0.0
    private let progressClip = CALayer(), progressBar = CALayer(), progressMask = CAShapeLayer()
    private var playbackDurationSeconds: Int?
    private var playback: SetlistPlaybackBinding?
    private var playbackSubscription: AnyCancellable?
    func bindPlayback(_ binding: SetlistPlaybackBinding?) {
        guard playback != binding else { return }
        playbackSubscription = nil; playback = binding
        playbackDurationSeconds = nil
        guard let binding else { return }
        playbackSubscription = binding.show.$snapshot.sink { [weak self] snapshot in
            self?.updatePlayback(snapshot.transport)
        }
    }
    private func updatePlayback(_ transport: TransportState) {
        guard let playback else { return }
        let start = playback.region.startTime
        let duration = max(0.001, playback.end - start)
        progress = active ? min(1, max(0, (transport.position - start) / duration)) : 0
        let queueLength = max(0.001, playback.playbackEnd - (transport.queueStartedAt ?? transport.position))
        queueProgress = queued ? min(1, max(0, playback.playbackEnd - transport.position) / queueLength) : 0
        let seconds = max(0, Int((active ? ceil(max(0, playback.end - transport.position)) : duration).rounded()))
        if seconds != playbackDurationSeconds {
            playbackDurationSeconds = seconds
            let text = regionDurationText(Double(seconds))
            if text != durationText {
                durationText = text; durationLine = Self.line(text, font: Self.durationFont)
                durationWidth = durationLine.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) } ?? 0
                truncationWidth = -1
                needsDisplay = true
            }
        }
        updateProgressLayer()
    }
    private var roundedBounds: CGRect = .null
    private var roundedPath: CGPath?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 34) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let actions = Dictionary(uniqueKeysWithValues: ["position", "bounds", "hidden", "backgroundColor", "path"].map { ($0, NSNull()) })
        for content in [progressClip, progressBar, progressMask] { content.actions = actions }
        progressClip.name = "setlist-progress-clip"
        progressBar.name = "setlist-progress-bar"
        progressClip.mask = progressMask
        progressMask.fillColor = NSColor.white.cgColor
        progressClip.addSublayer(progressBar)
        updateProgressLayer()
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func setFrameSize(_ size: NSSize) {
        let changed = frame.size != size
        super.setFrameSize(size)
        if changed { needsDisplay = true; updateProgressLayer() }
    }
    override func viewWillDraw() {
        super.viewWillDraw()
        updateProgressLayer()
    }
    private func updateProgressLayer() {
        // Only the moving strip changes at playback cadence. Keep the card's
        // cached text and gradient bitmap until its displayed content changes.
        if progressClip.superlayer !== layer { layer?.addSublayer(progressClip) }
        if progressClip.frame != bounds {
            progressClip.frame = bounds
            progressMask.frame = progressClip.bounds
            progressMask.path = RoundedRectangle(cornerRadius: 5).path(in: progressClip.bounds).cgPath
        }
        let hidden = !active && !queued
        if progressClip.isHidden != hidden { progressClip.isHidden = hidden }
        guard !hidden else { return }
        let color = active ? Self.green : Self.yellow
        if progressBar.backgroundColor != color { progressBar.backgroundColor = color }
        let frame = CGRect(x: 0, y: bounds.height - 2,
            width: bounds.width * min(1, max(0, active ? progress : queueProgress)), height: 2)
        if progressBar.frame != frame { progressBar.frame = frame }
    }
    func configure(number: Int, name: String, duration: String, color: UInt32, selected: Bool, active: Bool,
                   queued: Bool, prepareOnly: Bool, progress: Double, queueProgress: Double, fontStyle: Int = 0, nameColor: UInt32 = 0xffffff) {
        let numberString = String(format: "%02d", number)
        let textChanged = numberString != numberText || name != nameText || duration != durationText || nameColor != nameColorValue || fontStyle != fontStyleValue
        let styleChanged = color != colorValue || selected != self.selected || active != self.active || queued != self.queued || prepareOnly != self.prepareOnly
        guard textChanged || styleChanged || progress != self.progress || queueProgress != self.queueProgress else { return }
        if numberString != numberText {
            numberText = numberString; numberWidth = CGFloat(max(2,String(number).count)) * 6
            numberLine = Self.line(numberString, font: Self.numberFont, color: Self.secondary)
        }
        if name != nameText || nameColor != nameColorValue || fontStyle != fontStyleValue {
            fontStyleValue = fontStyle
            let baseFont = NSFont.systemFont(ofSize: 13, weight: fontStyle == 0 ? .regular : .bold)
            let font = fontStyle == 2 ? NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask) : baseFont
            nameColorValue = nameColor
            let ink = NSColor(Color(hex: nameColor))
            ellipsis = Self.line("…", font: font, color: ink)
            nameText = name; nameLine = Self.line(name, font: font, color: ink)
            nameWidth = nameLine.map { CGFloat(CTLineGetTypographicBounds($0,nil,nil,nil)) } ?? 0
            truncationWidth = -1
        }
        if duration != durationText {
            durationText = duration; durationLine = Self.line(duration, font: Self.durationFont)
            durationWidth = durationLine.map { CGFloat(CTLineGetTypographicBounds($0,nil,nil,nil)) } ?? 0
            truncationWidth = -1
            playbackDurationSeconds = nil
        }
        colorValue = color; self.selected = selected; self.active = active; self.queued = queued; self.prepareOnly = prepareOnly
        self.progress = progress; self.queueProgress = queueProgress
        if styleChanged { stripe = active ? Self.red : queued ? (prepareOnly ? Self.green : Self.orange) : NSColor(Color(hex: color)).cgColor }
        if textChanged { setAccessibilityLabel(numberString + ", " + name + ", " + duration) }
        updateProgressLayer()
        if textChanged || styleChanged { needsDisplay = true }
    }
    private static func line(_ text: String, font: NSFont, color: NSColor = .white) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, bounds.width > 0 else { return }
        if roundedBounds != bounds {
            roundedBounds = bounds
            roundedPath = RoundedRectangle(cornerRadius: 5).path(in: bounds).cgPath
        }
        guard let rounded = roundedPath else { return }
        context.saveGState(); context.addPath(rounded); context.clip()
        if active || queued || selected {
            let index = active ? 0 : queued ? (prepareOnly ? 1 : 2) : 3
            context.drawLinearGradient(Self.gradients[index], start: CGPoint(x: bounds.minX,y:0), end: CGPoint(x:bounds.maxX,y:0), options: [])
        } else { context.setFillColor(Self.panel); context.fill(bounds) }
        context.setFillColor(stripe)
        context.addPath(CGPath(roundedRect: CGRect(x:8,y:7,width:3,height:20), cornerWidth:2,cornerHeight:2,transform:nil));context.fillPath()
        let nameX: CGFloat = 8 + 3 + 6 + numberWidth + 6
        let durationX = bounds.width - 8 - durationWidth
        let available = max(0, durationX - 6 - nameX)
        // Reuse the shaped title; resizing only updates its final ellipsis.
        if available != truncationWidth {
            truncationWidth = available
            truncatedName = nameWidth <= available ? nameLine : nameLine.flatMap { CTLineCreateTruncatedLine($0,Double(available),.end,ellipsis) }
        }
        draw(numberLine,x:17,in:context)
        if available > 0 { draw(truncatedName,x:nameX,in:context) }
        draw(durationLine,x:durationX,in:context)
        context.restoreGState()
        if selected && !active && !queued { context.setStrokeColor(Self.green);context.setLineWidth(1.5);context.addPath(rounded);context.strokePath() }
    }
    private func draw(_ line: CTLine?, x: CGFloat, in context: CGContext) {
        guard let line else { return }
        var ascent: CGFloat=0, descent: CGFloat=0
        CTLineGetTypographicBounds(line,&ascent,&descent,nil)
        let baseline = (bounds.height - ascent - descent) / 2 + ascent
        context.saveGState();context.textMatrix = .identity;context.translateBy(x:x,y:baseline);context.scaleBy(x:1,y:-1)
        CTLineDraw(line,context);context.restoreGState()
    }
}
#endif

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
    let playlist: (Int) -> String?
    let released: () -> Void
    let delete: () -> Void
    func makeNSView(context: Context) -> SetlistKeyView { SetlistKeyView() }
    func updateNSView(_ view: SetlistKeyView, context: Context) { view.move = move; view.playlist = playlist; view.search = search; view.released = released; view.delete = delete }
}
final class SetlistKeyView: NSView {
    var search: (() -> Bool)?
    var move: ((Int) -> Bool)?
    var playlist: ((Int) -> String?)?
    var released: (() -> Void)?
    var delete: (() -> Void)?
    private static weak var deleteOwner: SetlistKeyView?
    static func handleDelete(_ event: NSEvent) -> Bool {
        if RegionShortcutView.handleSelectedObjectsDelete(event) { return true }
        guard [51,117].contains(event.keyCode), event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty,
              let owner = deleteOwner, event.window === owner.window, owner.acceptsNavigation,
              !(owner.window?.firstResponder is any TimelineGridKeyboardTarget),
              !owner.isHiddenOrHasHiddenAncestor, owner.visibleRect.width > 0 else { return false }
        owner.stopRepeating(commit: false)
        if !event.isARepeat { owner.delete?() }
        // Consume even a protected drawer selection, so Delete cannot fall
        // through to stale selections in the grid or Track-Mixer.
        return true
    }
    func notePointerEvent(_ event: NSEvent) {
        guard event.window === window else { return }
        if visibleRect.contains(convert(event.locationInWindow, from: nil)) {
            if window?.firstResponder is any TimelineGridKeyboardTarget { window?.makeFirstResponder(nil) }
            Self.deleteOwner = self
        }
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
            let playlistModifiers = event.modifierFlags.intersection([.command,.control,.option,.shift])
            if event.window === self.window, self.acceptsNavigation, [125,126].contains(event.keyCode),
               playlistModifiers == .command || playlistModifiers == .control || playlistModifiers == [.command, .control] {
                self.stopRepeating(commit: false)
                if let name = self.playlist?(event.keyCode == 125 ? 1 : -1), let window = self.window {
                    PlaylistSelectionNotice.shared.present(name, in: window)
                }
                return nil
            }
            if RegionShortcutView.handleSelectedObjectsDelete(event) { self.stopRepeating(commit: false); return nil }
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
            if self.window?.firstResponder is any TimelineGridKeyboardTarget { self.window?.makeFirstResponder(nil) }
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
    override func scrollWheel(with event: NSEvent) {
        // This native overlay handles selection modifiers. SwiftUI's hosting
        // responder can swallow wheel events, so deliver them to the list.
        if let scroll = enclosingScrollView { scroll.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
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
    var fontStyle: Int = 0
    var selected = false
    var body: some View {
        HStack(spacing: 8) {
            if block.showsSymbol {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 6)); path.addLine(to: CGPoint(x: 62, y: 6))
                    path.move(to: CGPoint(x: 56, y: 0)); path.addLine(to: CGPoint(x: 62, y: 6)); path.addLine(to: CGPoint(x: 56, y: 12))
                }.stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 62, height: 12).accessibilityHidden(true)
            }
            Text(block.name).font(fontStyle == 2 ? .system(size: 13, weight: .bold).italic() : .system(size: 13, weight: fontStyle == 0 ? .regular : .bold)).lineLimit(1)
                .foregroundStyle(JarasTheme.green)
        }.padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 24)
            .background {
                if selected {
                    LinearGradient(colors: [Color(hex: 0x2457a9), Color(hex: 0x152b58)], startPoint: .leading, endPoint: .trailing)
                } else { Color(hex: block.color).opacity(0.15) }
            }.clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: block.color).opacity(0.5)))
            .contentShape(Rectangle()).accessibilityLabel(block.name)
    }
}
/// One indicator per drag; cancellation outside the list must also clear it.
private final class SetlistReorderState: ObservableObject {
    static let shared = SetlistReorderState()
    @Published var target: UUID?
    @Published private(set) var after = false
    private(set) var scope: String?
    #if os(macOS)
    var source: SetlistNativeDragSource?
    #endif
    func begin(scope: String) { finish(); self.scope = scope }
    func indicate(_ entry: UUID, after: Bool) {
        guard scope != nil else { return }
        if self.after != after { self.after = after }
        if target != entry { target = entry }
    }
    func finish() {
        scope = nil
        if target != nil { target = nil }
        #if os(macOS)
        source = nil
        #endif
    }
}
private struct PlaylistRegionDrag: ViewModifier {
    let show: ShowController
    let playlist: UUID?
    let entry: UUID
    let block: Bool
    @Binding var selection: Set<UUID>
    var locked = false
    var name = ""
    @ObservedObject private var drag = SetlistReorderState.shared
    private var insertionAfter: Bool? { drag.target == entry && drag.scope == scope ? drag.after : nil }
    private var scope: String { (show.current?.id.uuidString ?? "") + ":" + (playlist?.uuidString ?? "all") }
    @ViewBuilder func body(content: Content) -> some View {
        if locked { content.modifier(LockedRegionDrag()) }
        else {
            draggable(content)
                .onDrop(of: [SetlistInsertionDrop.type], delegate: SetlistInsertionDrop(
                    show: show, scope: scope, entry: entry, height: block ? 24 : 34, state: drag))
                .overlay(alignment: insertionAfter == true ? .bottom : .top) {
                    if insertionAfter != nil {
                        Rectangle().fill(JarasTheme.green).frame(height: 3)
                            .shadow(color: JarasTheme.green, radius: 4).allowsHitTesting(false)
                    }
                }
        }
    }
    private func dragPayload() -> String {
        if !selection.contains(entry) { selection = [entry] }
        let ids = show.setlistEntries.filter {
            guard selection.contains($0.id) else { return false }
            if playlist == nil, case .region = $0 { return false }
            return true
        }.map { $0.id.uuidString }.joined(separator: ",")
        drag.begin(scope: scope)
        return "jaras-setlist:" + scope + ":" + ids
    }
    @ViewBuilder private func draggable(_ content: Content) -> some View {
        if block || playlist != nil {
            #if os(macOS)
            // A native source follows the row after LazyVStack reorders it and
            // reports cancellation, without replacing row identities or data.
            content.background(SetlistNativeDrag(identity: scope + ":" + entry.uuidString,
                                                 name: name, state: drag, payload: dragPayload))
            #else
            content.onDrag { NSItemProvider(object: dragPayload() as NSString) }
            #endif
        } else { content }
    }
}
#if os(macOS)
private struct SetlistNativeDrag: NSViewRepresentable {
    let identity: String
    let name: String
    let state: SetlistReorderState
    let payload: () -> String
    func makeNSView(context: Context) -> SetlistNativeDragView { SetlistNativeDragView() }
    func updateNSView(_ view: SetlistNativeDragView, context: Context) {
        view.identity = identity; view.name = name; view.state = state; view.payload = payload
    }
}
private final class SetlistNativeDragView: NSView {
    var identity = ""
    var name = ""
    weak var state: SetlistReorderState?
    var payload: (() -> String)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { SetlistNativeDragRouter.shared.add(self) }
    }
}
private final class SetlistNativeDragSource: NSObject, NSDraggingSource {
    weak var state: SetlistReorderState?
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { state?.finish() }
}
@MainActor private final class SetlistNativeDragRouter {
    static let shared = SetlistNativeDragRouter()
    private let rows = NSHashTable<SetlistNativeDragView>.weakObjects()
    private var monitor: Any?
    private weak var pressedRow: SetlistNativeDragView?
    private var pressedIdentity = ""
    private var start: NSPoint?
    func add(_ row: SetlistNativeDragView) {
        rows.add(row)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }
    private func handle(_ event: NSEvent) -> Bool {
        if event.type == .leftMouseUp { pressedRow = nil; start = nil; return false }
        if event.type == .leftMouseDown {
            pressedRow = nil; start = nil
            guard let window = event.window, window.attachedSheet == nil,
                  !event.modifierFlags.contains(.control) else { return false }
            pressedRow = rows.allObjects.first { row in
                let point = row.convert(event.locationInWindow, from: nil)
                return row.window === window && !row.isHiddenOrHasHiddenAncestor &&
                    row.bounds.contains(point) && row.visibleRect.contains(point)
            }
            pressedIdentity = pressedRow?.identity ?? ""; start = event.locationInWindow
            return false
        }
        guard let row = pressedRow, let start, row.window === event.window,
              row.identity == pressedIdentity, let state = row.state, let payload = row.payload,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return false }
        pressedRow = nil; self.start = nil
        let text = payload()
        let source = SetlistNativeDragSource(); source.state = state; state.source = source
        let item = NSDraggingItem(pasteboardWriter: text as NSString)
        let size = NSSize(width: max(80, min(300, row.bounds.width)), height: 34)
        let title = NSAttributedString(string: row.name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
        let preview = NSImage(size: size, flipped: true) { rect in
            NSColor.controlBackgroundColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            title.draw(in: rect.insetBy(dx: 8, dy: 9)); return true
        }
        let point = row.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - size.width / 2, y: point.y - 17, width: size.width, height: size.height), contents: preview)
        let session = row.beginDraggingSession(with: [item], event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = false
        return true
    }
}
#endif

private struct SetlistInsertionDrop: DropDelegate {
    static let type = UTType.text
    let show: ShowController
    let scope: String
    let entry: UUID
    let height: CGFloat
    let state: SetlistReorderState
    func validateDrop(info: DropInfo) -> Bool { state.scope == scope && info.hasItemsConforming(to: [Self.type]) }
    func dropEntered(info: DropInfo) { state.indicate(entry, after: info.location.y >= height / 2) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard state.scope == scope else { return DropProposal(operation: .forbidden) }
        state.indicate(entry, after: info.location.y >= height / 2)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { if state.target == entry { state.target = nil } }
    func performDrop(info: DropInfo) -> Bool {
        let insertAfter = info.location.y >= height / 2
        guard state.scope == scope else { return false }
        state.finish()
        guard let provider = info.itemProviders(for: [Self.type]).first else { return false }
        _ = provider.loadObject(ofClass: String.self) { value, _ in
            guard let value else { return }
            let parts = value.split(separator: ":")
            guard parts.count == 4, parts[0] == "jaras-setlist",
                  String(parts[1]) + ":" + String(parts[2]) == scope else { return }
            let ids = Set(parts[3].split(separator: ",").compactMap { UUID(uuidString: String($0)) })
            Task { @MainActor in
                let currentScope = (show.current?.id.uuidString ?? "") + ":" + (show.selectedRegionPlaylist?.id.uuidString ?? "all")
                guard currentScope == scope else { return }
                show.moveSetlistEntries(ids, relativeTo: entry, after: insertAfter)
            }
        }
        return true
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
    var body: some View {
        Button(action: action) {
            Text("STOP").font(.system(size: 9, weight: .bold))
                .foregroundStyle(active ? JarasTheme.green : Color.red)
                .padding(.horizontal, 6).frame(height: 26)
                .background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(active ? JarasTheme.green : .red, lineWidth: 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).modifier(JarasBlink(active: active, interval: 0.55))
            .jarasHelp("Stop automatically at the end of each region").accessibilityLabel("Region stop")
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

#if os(macOS)
private final class PlaylistSelectionNotice {
    static let shared = PlaylistSelectionNotice()
    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?
    func present(_ name: String, in owner: NSWindow) {
        dismissal?.cancel()
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        let notice = NSPanel(contentRect: NSRect(x: 0,y: 0,width: 380,height: 90),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        notice.isReleasedWhenClosed = false; notice.isOpaque = false; notice.backgroundColor = .clear
        notice.ignoresMouseEvents = true; notice.hasShadow = true
        notice.contentView = NSHostingView(rootView: Text(name).font(.system(size: 22,weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
            .foregroundStyle(JarasTheme.text).padding(18).frame(width: 380,height: 90)
            .background(RoundedRectangle(cornerRadius: 10).fill(JarasTheme.panel))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(JarasTheme.green,lineWidth: 1)))
        notice.setFrameOrigin(NSPoint(x: owner.frame.midX - 190,y: owner.frame.midY - 45))
        owner.addChildWindow(notice, ordered: .above); notice.orderFront(nil); panel = notice
        let work = DispatchWorkItem { [weak self, weak notice] in
            guard let notice else { return }
            notice.parent?.removeChildWindow(notice); notice.orderOut(nil)
            if self?.panel === notice { self?.panel = nil }
        }
        dismissal = work; DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
#endif
