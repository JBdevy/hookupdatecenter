import Foundation
import Combine
@MainActor public final class ShowController: ObservableObject {
    @Published public private(set) var snapshot: ShowSnapshot
    @Published public private(set) var focusedRegion: UUID?
    public private(set) var restoredCursorPosition: Double?
    @Published public private(set) var regionFocusRequest = UUID()
    private var regionNavigationTask: Task<Void, Never>?
    public func stepRegion(_ direction: Int, entries: [SetlistEntry]? = nil, commitAfterDelay: Bool = true) {
        regionNavigationTask?.cancel(); regionNavigationTask = nil
        let regions = entries?.compactMap { entry -> Part? in
            if case .region(let region, _) = entry { return region }
            return nil
        } ?? listedRegions
        guard !regions.isEmpty else { return }
        let anchor = regions.contains(where: { $0.id == focusedRegion }) ? focusedRegion :
            current?.parts.first(where: { $0.id == focusedRegion })?.parentRegionID
        let index: Int
        if let selected = regions.firstIndex(where: { $0.id == anchor }) {
            index = min(regions.count - 1, max(0, selected + direction))
            guard index != selected else { if commitAfterDelay { finishRegionNavigation() }; return }
        } else { index = direction < 0 ? regions.count - 1 : 0 }
        let id = regions[index].id
        focusedRegion = id
        if commitAfterDelay { finishRegionNavigation() }
    }
    public func finishRegionNavigation() {
        regionNavigationTask?.cancel()
        guard let id = focusedRegion else { return }
        regionNavigationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            guard let self, self.focusedRegion == id else { return }
            if self.snapshot.transport.playing {
                // Browsing highlights another song without replacing the armed queue.
                self.regionFocusRequest = UUID()
                return
            }
            self.focusRegion(id)
        }
    }
    public func focusRegion(_ id: UUID) {
        restoredCursorPosition = nil
        regionNavigationTask?.cancel(); regionNavigationTask = nil
        guard let region = current?.parts.first(where: { $0.id == id }) else { return }
        if snapshot.transport.playing, let parent = region.parentRegionID,
           let active = current?.parts.first(where: { $0.id == snapshot.transport.regionId }),
           active.id == parent || active.parentRegionID == parent {
            message = "Cannot queue a song from the active unified region"
            return
        }
        send(snapshot.transport.playing ? .queueRegion : .selectRegion, target: region.id)
        focusedRegion = id
        regionFocusRequest = UUID()
    }
    public func searchRegions(_ query: String) -> [Part] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (current?.parts ?? []).filter { term.isEmpty || $0.name.localizedStandardContains(term) }.sorted { $0.startTime < $1.startTime }
    }
    @discardableResult public func selectRegionSearchResult(_ id: UUID) -> Bool {
        guard canExecute(), !finishing, current?.parts.contains(where: { $0.id == id }) == true else { return false }
        let listID = current?.parts.first(where: { $0.id == id })?.parentRegionID ?? id
        if let playlist = selectedRegionPlaylist, !playlist.regionIds.contains(listID) {
            var state = regionSetlist
            state.selectedId = nil
            guard configureRegionSetlist(state) else { return false }
        }
        focusRegion(id)
        return true
    }
    public var regionSetlist: RegionSetlist { snapshot.project.regionSetlist ?? RegionSetlist() }
    public var allRegions: [Part] { (current?.parts ?? []).filter { $0.parentRegionID == nil }.sorted { $0.startTime == $1.startTime ? $0.id.uuidString < $1.id.uuidString : $0.startTime < $1.startTime } }
    public var selectedRegionPlaylist: RegionPlaylist? { regionSetlist.playlists.first { $0.id == regionSetlist.selectedId && $0.songId == current?.id } }
    public var listedRegions: [Part] {
        guard let list = selectedRegionPlaylist else { return allRegions.filter { $0.parentRegionID == nil } }
        let lookup = Dictionary(uniqueKeysWithValues: (current?.parts ?? []).map { ($0.id, $0) })
        return list.regionIds.compactMap { lookup[$0] }.filter { $0.parentRegionID == nil }
    }
    public var listedBlocks: [SetlistBlock] {
        (regionSetlist.blocks ?? []).filter { $0.songId == current?.id && $0.playlistId == selectedRegionPlaylist?.id }
    }
    public var setlistEntries: [SetlistEntry] {
        let blocks = Dictionary(grouping: listedBlocks, by: \.beforeRegionId)
        var entries: [SetlistEntry] = []
        for (index,region) in listedRegions.enumerated() {
            entries += (blocks[region.id] ?? []).map(SetlistEntry.block)
            entries.append(.region(region, number: index + 1))
        }
        entries += (blocks[nil] ?? []).map(SetlistEntry.block)
        return entries
    }
    @discardableResult public func addSetlistBlock(symbol: Bool = true, namePrefix: String = "Bloco") -> UUID? {
        guard let song = current, let playlist = selectedRegionPlaylist else { return nil }
        let color = UInt32.random(in: 80...230) << 16 | UInt32.random(in: 80...230) << 8 | UInt32.random(in: 80...230)
        let selected = listedRegions.first { $0.id == focusedRegion }
        let block = SetlistBlock(id: UUID(), songId: song.id, playlistId: playlist.id,
                                 name: namePrefix + String(format: " %02d", listedBlocks.count + 1), color: color,
                                 beforeRegionId: selected?.id ?? listedRegions.first?.id, symbol: symbol)
        var state = regionSetlist
        // An explicit selection inserts immediately above that song; otherwise start the list.
        state.blocks = selected == nil ? [block] + (state.blocks ?? []) : (state.blocks ?? []) + [block]
        return configureRegionSetlist(state) ? block.id : nil
    }
    public func editSetlistBlock(_ id: UUID, name: String, color: UInt32, symbol: Bool? = nil) {
        var state = regionSetlist
        guard let index = state.blocks?.firstIndex(where: { $0.id == id }) else { return }
        state.blocks?[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        state.blocks?[index].color = color
        if let symbol { state.blocks?[index].symbol = symbol }
        _ = configureRegionSetlist(state)
    }
    public func moveSetlistBlock(_ id: UUID, relativeTo target: UUID, after: Bool) {
        let entries = setlistEntries
        guard id != target, listedBlocks.contains(where: { $0.id == id }), let targetIndex = entries.firstIndex(where: { $0.id == target }) else { return }
        let insertion = targetIndex + (after ? 1 : 0)
        let following = entries.dropFirst(insertion).filter { $0.id != id }
        let anchor = following.compactMap { entry -> UUID? in if case .region(let region, _) = entry { return region.id }; return nil }.first
        var state = regionSetlist
        guard var blocks = state.blocks, let source = blocks.firstIndex(where: { $0.id == id }) else { return }
        var block = blocks.remove(at: source); block.beforeRegionId = anchor
        if let nextBlock = following.first, case .block(let next) = nextBlock, let index = blocks.firstIndex(where: { $0.id == next.id }) {
            blocks.insert(block, at: index)
        } else { blocks.append(block) }
        state.blocks = blocks
        _ = configureRegionSetlist(state)
    }
    public func moveSetlistEntries(_ ids: Set<UUID>, relativeTo target: UUID, after: Bool) {
        let entries = setlistEntries
        guard !ids.contains(target), entries.contains(where: { $0.id == target }) else { return }
        let moving = entries.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        if selectedRegionPlaylist == nil, moving.contains(where: { if case .region = $0 { return true }; return false }) { return }
        var ordered = entries.filter { !ids.contains($0.id) }
        guard let index = ordered.firstIndex(where: { $0.id == target }) else { return }
        ordered.insert(contentsOf: moving, at: index + (after ? 1 : 0))
        guard ordered.map(\.id) != entries.map(\.id) else { return }
        var state = regionSetlist
        if let playlist = selectedRegionPlaylist, let list = state.playlists.firstIndex(where: { $0.id == playlist.id }) {
            state.playlists[list].regionIds = ordered.compactMap { if case .region(let region, _) = $0 { return region.id }; return nil }
        }
        var anchor: UUID?
        var blocks: [SetlistBlock] = []
        for entry in ordered.reversed() {
            switch entry {
            case .region(let region, _): anchor = region.id
            case .block(var block): block.beforeRegionId = anchor; blocks.append(block)
            }
        }
        let visible = Set(listedBlocks.map(\.id))
        state.blocks = (state.blocks ?? []).filter { !visible.contains($0.id) } + blocks.reversed()
        _ = configureRegionSetlist(state)
    }
    public func createRegionPlaylist(name: String, selected: Set<UUID>) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !selected.isEmpty, let song = current else { return false }
        let ids = allRegions.filter { selected.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return false }
        var state = regionSetlist
        let list = RegionPlaylist(id: UUID(), name: name, songId: song.id, regionIds: ids)
        state.playlists.append(list); state.selectedId = list.id
        return configureRegionSetlist(state)
    }
    public func selectRegionPlaylist(_ id: UUID?) {
        var state = regionSetlist; state.selectedId = id; _ = configureRegionSetlist(state)
    }
    public func reorderPlaylistRegion(_ region: UUID, relativeTo target: UUID, after: Bool, playlist: UUID) {
        guard selectedRegionPlaylist?.id == playlist, region != target else { return }
        var state = regionSetlist
        guard let index = state.playlists.firstIndex(where: { $0.id == playlist }),
              let sourceIndex = state.playlists[index].regionIds.firstIndex(of: region),
              state.playlists[index].regionIds.contains(target) else { return }
        state.playlists[index].regionIds.remove(at: sourceIndex)
        guard let targetIndex = state.playlists[index].regionIds.firstIndex(of: target) else { return }
        state.playlists[index].regionIds.insert(region, at: targetIndex + (after ? 1 : 0))
        if state != regionSetlist { _ = configureRegionSetlist(state) }
    }
    public func setPrepareWithoutPlayback(_ enabled: Bool) {
        var state = regionSetlist; state.prepareWithoutPlayback = enabled; _ = configureRegionSetlist(state)
    }
    private func focusPreparedRegion(previous: TransportState) {
        guard !snapshot.transport.playing, let queued = previous.queuedRegionId,
              snapshot.transport.regionId == queued else { return }
        regionNavigationTask?.cancel(); regionNavigationTask = nil
        focusedRegion = queued; regionFocusRequest = UUID()
    }
    public func toggleRegionAuto() {
        var state = regionSetlist; state.autoAdvance.toggle(); _ = configureRegionSetlist(state)
    }
    public func toggleRegionStop() {
        var state = regionSetlist; state.stopAtRegionEnd = !state.stopsAtRegionEnd; _ = configureRegionSetlist(state)
    }
    @discardableResult private func configureRegionSetlist(_ state: RegionSetlist) -> Bool {
        guard canExecute(), !finishing else { return false }
        do {
            try executor.configureRegionSetlist(state)
            let playback = try executor.playbackSnapshot()
            snapshot.project.regionSetlist = state
            snapshot.transport = playback.transport; snapshot.nextSongId = playback.nextSongId
            recordEdit()
            setlistRevision &+= 1; hasUnsavedChanges = true
            onSetlistEdited()
            return true
        }
        catch { message = error.localizedDescription; return false }
    }
    @Published public var message = ""
    public var current: Song? { snapshot.project.songs.first { $0.id == snapshot.transport.songId } }
    public var next: Song? { snapshot.project.songs.first { $0.id == snapshot.nextSongId } }
    @Published public private(set) var subCursorPreview = false
    private var subCursorHideTask: Task<Void, Never>?
    public var subCursorVisible: Bool { subCursorPreview || snapshot.transport.subPlay.playing }
    private func revealSubCursor() {
        subCursorHideTask?.cancel()
        subCursorPreview = true
        subCursorHideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            self?.subCursorPreview = false
        }
    }
    public struct TrackSelectionRequest: Equatable {
        public let id: UUID
        public let track: UUID
    }
    @Published public private(set) var trackSelectionRequest: TrackSelectionRequest?
    public struct SetlistNavigationRequest: Equatable {
        public let id: UUID
        public let direction: Int
    }
    @Published public private(set) var setlistNavigationRequest: SetlistNavigationRequest?
    @Published public private(set) var splitItemsRequest: UInt64 = 0
    @Published public private(set) var addTrackRequest: UInt64 = 0
    public private(set) var selectedTrackForActions: UUID?
    private var tempoTaps = TapTempo()
    public func reportTrackSelection(_ track: UUID?) { selectedTrackForActions = track }
    public func resetTapTempo() { tempoTaps = TapTempo() }
    public func tapTempo(at time: Double = ProcessInfo.processInfo.systemUptime) {
        if let bpm = tempoTaps.tap(at: time) { setTempo(bpm) }
    }
    public func actionTrack(number: Int?) -> Track? {
        guard let tracks = current?.tracks else { return nil }
        if let number {
            guard tracks.indices.contains(number - 1), tracks[number - 1].kind == .standard else { return nil }
            return tracks[number - 1]
        }
        return tracks.first { $0.id == selectedTrackForActions && $0.kind == .standard } ?? tracks.first { $0.kind == .standard }
    }
    public func performAction(_ action: DAWAction, trackNumber: Int? = nil, midiValue: UInt8? = nil) {
        guard canExecute(), !finishing else { return }
        let track = action.needsTrack ? actionTrack(number: trackNumber) : nil
        if action.needsTrack && track == nil { message = "Track unavailable"; return }
        switch action {
        case .selectTrack:
            if let track { selectedTrackForActions = track.id; trackSelectionRequest = TrackSelectionRequest(id: UUID(), track: track.id) }
        case .muteTrack: send(.mute, target: track?.id)
        case .soloTrack: send(.solo, target: track?.id)
        case .volumeTrack:
            if let midiValue { send(.volume, target: track?.id, value: MIDIFaderValue.gain(midiValue)) }
        case .panTrack:
            if let midiValue { send(.pan, target: track?.id, value: DAWActionValue.pan(midiValue)) }
        case .tempoDown: adjustTempo(-1)
        case .tempoUp: adjustTempo(1)
        case .tapTempo: tapTempo()
        case .playStop: send(snapshot.transport.playing ? .stop : .play)
        case .pause: send(.pause)
        case .repeatPlayback: send(.toggleLoop)
        case .subPlayStop: send(snapshot.transport.subPlay.playing ? .subStop : .subPlay)
        case .addTrack: addTrackRequest &+= 1
        case .setlistUp, .setlistDown: setlistNavigationRequest = SetlistNavigationRequest(id: UUID(), direction: action == .setlistUp ? -1 : 1)
        case .toggleAuto: toggleRegionAuto()
        case .ignoreNext: send(.ignoreNext)
        case .splitItems: splitItemsRequest &+= 1
        }
    }
    public var isPlaying: Bool { snapshot.transport.playing || snapshot.transport.subPlay.playing }
    public var canExecute: () -> Bool = { true }
    public var onStop: () -> Void = {}
    public var onSetlistEdited: () -> Void = {}
    public var audioUpdate: (ShowSnapshot, UInt64) -> Void = { _, _ in }
    public var audioFX: (UUID?, NativeFXSettings) -> Void = { _, _ in }
    public var audioClipFX: (UUID, NativeFXSettings) -> Void = { _, _ in }
    public var audioClipFXBypass: (UUID, Bool) -> Void = { _, _ in }
    private var clipFXDefaults: [UUID: NativeFXSettings] = [:]
    private var effectRevision: UInt64 = 0
    private var pendingFXEdit = false
    public private(set) var setlistRevision: UInt64 = 0
    public var audioItemGain: (UUID, Double) -> Void = { _, _ in }
    public var audioVolume: (UUID?, Double) -> Void = { _, _ in }
    public var audioPan: (UUID, Double) -> Void = { _, _ in }
    public var audioMute: (UUID?, Bool) -> Void = { _, _ in }
    public var audioSolo: (UUID, Bool) -> Void = { _, _ in }
    public var audioClipMute: (UUID, Bool) -> Void = { _, _ in }
    public var prepareForSave: () -> Void = {}
    public var audioRouting: ([UUID: TrackRouting]) -> Void = { _ in }
    public var audioPatches: (UUID?, [OutputPatch]) -> Void = { _, _ in }
    public var audioPatch: (UUID?, OutputPatch, Int) -> Void = { _, _, _ in }
    public var audioMIDIInput: (UUID, Int) -> Void = { _, _ in }
    private let executor: any CommandExecutor, persistence: any ProjectPersistence
    private let cursorMemory: ProjectCursorMemory?
    private var timer: Timer?, lastTime = ProcessInfo.processInfo.systemUptime
    @Published public private(set) var hasUnsavedChanges = false
    @Published public private(set) var saving = false
    public private(set) var projectRevision: UInt64 = 0
    private var audioProjectRevision: UInt64 = 0
    private var finishing = false
    private var history: ProjectEditHistory?
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false
    public private(set) var knownMediaPaths = Set<String>()
    public var onProjectEdited: () -> Void = {}
    public func discardClosedHistory() { resetHistory() }
    public func undo() { restoreEdit(redo: false) }
    public func redo() { restoreEdit(redo: true) }
    private func recordEdit() {
        history?.record(snapshot.project)
        canUndo = history?.canUndo == true; canRedo = history?.canRedo == true
        knownMediaPaths.formUnion(snapshot.project.mediaPaths)
    }
    private func resetHistory() {
        pendingFXEdit = false
        clipFXDefaults.removeAll(keepingCapacity: true)
        history = ProjectEditHistory(snapshot.project); canUndo = false; canRedo = false
        knownMediaPaths = snapshot.project.mediaPaths
    }
    private func restoreEdit(redo: Bool) {
        if pendingFXEdit { commitFX() }
        guard canExecute(), !finishing, var next = history else { return }
        guard let project = redo ? next.redo() : next.undo() else { return }
        do {
            tick(); try executor.applyProjectEdit(project)
            snapshot = try executor.snapshot(); history = next
            canUndo = next.canUndo; canRedo = next.canRedo
            projectRevision &+= 1; hasUnsavedChanges = true
            audioProjectRevision &+= 1
            if let focusedRegion, current?.parts.contains(where: { $0.id == focusedRegion }) != true { self.focusedRegion = nil }
            onProjectEdited(); audioUpdate(snapshot, audioProjectRevision)
        } catch { message = error.localizedDescription }
    }
    private func editProject(_ edit: (inout Project) -> Void) {
        guard canExecute(), !finishing else { return }
        var project = snapshot.project; edit(&project)
        guard project != snapshot.project else { return }
        do {
            tick(); try executor.applyProjectEdit(project)
            snapshot = try executor.snapshot(); markChanged(); onProjectEdited()
        } catch { message = error.localizedDescription }
    }
    public func previewItemGain(_ id: UUID, gain: Double) { audioItemGain(id, gain) }
    public func setItemGain(_ id: UUID, gain: Double) {
        guard canExecute(), !finishing, gain.isFinite, gain >= 0 else { return }
        let value = min(pow(10, 12.0 / 20), gain)
        for song in snapshot.project.songs.indices {
            for track in snapshot.project.songs[song].tracks.indices where snapshot.project.songs[song].tracks[track].kind == .standard {
                guard let index = snapshot.project.songs[song].tracks[track].clips.firstIndex(where: { $0.id == id }) else { continue }
                let previous = snapshot.project.songs[song].tracks[track].clips[index].gain ?? 1
                guard previous != value else { return }
                do {
                    tick()
                    // Commit one scalar to the engine, retaining the existing Swift
                    // waveform arrays instead of serializing the whole project.
                    try executor.execute(.clipGain, target: id, value: value)
                    snapshot.project.songs[song].tracks[track].clips[index].gain = value
                    audioItemGain(id, value)
                    markChanged(refreshAudio: false)
                } catch {
                    audioItemGain(id, previous); message = error.localizedDescription
                }
                return
            }
        }
    }
    public func resizeItem(_ id: UUID, start: Double, end: Double) { editProject { $0.resizeItem(id, start: start, end: end) } }
    public func splitItems(_ ids: Set<UUID>, at position: Double) { editProject { $0.splitItems(ids, at: position) } }
    @discardableResult public func normalizeItems(_ gains: [UUID: Double], project: UUID) -> Bool {
        guard canExecute(), !finishing, snapshot.project.id == project, !gains.isEmpty else { return false }
        var edits: [(song: Int, track: Int, item: Int, id: UUID, old: Double, gain: Double)] = []
        for song in snapshot.project.songs.indices {
            for track in snapshot.project.songs[song].tracks.indices where snapshot.project.songs[song].tracks[track].kind == .standard {
                for item in snapshot.project.songs[song].tracks[track].clips.indices {
                    let clip = snapshot.project.songs[song].tracks[track].clips[item]
                    if let gain = gains[clip.id], gain.isFinite, gain >= 0 {
                        edits.append((song, track, item, clip.id, clip.gain ?? 1, min(pow(10, 12.0 / 20), gain)))
                    }
                }
            }
        }
        guard edits.count == gains.count else { return false }
        var applied = 0
        do {
            for edit in edits { try executor.execute(.clipGain, target: edit.id, value: edit.gain); applied += 1 }
            for edit in edits {
                snapshot.project.songs[edit.song].tracks[edit.track].clips[edit.item].gain = edit.gain
                audioItemGain(edit.id, edit.gain)
            }
            if edits.contains(where: { $0.gain != $0.old }) { markChanged(refreshAudio: false) }
            return true
        } catch {
            for edit in edits.prefix(applied) { try? executor.execute(.clipGain, target: edit.id, value: edit.old) }
            message = error.localizedDescription
            return false
        }
    }
    private var itemClipboard: GridItemClipboard?
    @discardableResult public func copyItems(_ ids: Set<UUID>, moving: Bool = false) -> Bool {
        guard canExecute(), !finishing, let song = current?.id,
              let copied = GridItemClipboard(project: snapshot.project, song: song, selected: ids, moving: moving) else { return false }
        if pendingFXEdit { commitFX() }
        itemClipboard = copied
        return true
    }
    @discardableResult public func pasteItems() -> Set<UUID> {
        guard canExecute(), !finishing, let clipboard = itemClipboard, clipboard.song == current?.id else { return [] }
        do {
            let position = snapshot.transport.editPosition ?? snapshot.transport.position
            let entries = try clipboard.items(in: snapshot.project, at: position)
            var project = snapshot.project
            try project.pasteItems(entries, song: clipboard.song, moving: clipboard.moving)
            if project != snapshot.project {
                tick(); try executor.pasteItems(entries, song: clipboard.song, moving: clipboard.moving)
                snapshot.project = project; markChanged(); onProjectEdited()
            }
            let ids = Set(entries.map { $0.clip.id })
            if clipboard.moving { itemClipboard = GridItemClipboard(project: project, song: clipboard.song, selected: ids) }
            message = ""
            return ids
        } catch { message = error.localizedDescription; return [] }
    }
    public func deleteItems(_ ids: Set<UUID>) { editProject { $0.deleteItems(ids) } }
    public func deleteTracks(_ ids: Set<UUID>) { editProject { $0.deleteTracks(ids) } }
    public func ungroupTrack(_ id: UUID) { editProject { $0.ungroupTrack(id) } }
    public func deleteRegion(_ id: UUID, playlist: UUID?) {
        if let playlist { editProject { $0.removeRegion(id, from: playlist) } }
        else { editProject { $0.deleteRegion(id) }; if focusedRegion == id { focusedRegion = nil } }
    }
    public func deletableSetlistEntries(_ ids: Set<UUID>) -> Set<UUID> {
        Set(setlistEntries.lazy.filter { ids.contains($0.id) }.map(\.id))
    }
    @discardableResult public func deleteSetlistEntries(_ ids: Set<UUID>) -> Bool {
        guard let song = current else { return false }
        let ids = deletableSetlistEntries(ids)
        guard !ids.isEmpty else { return false }
        let before = snapshot.project
        var edited = before
        edited.deleteSetlistEntries(ids, song: song.id, playlist: selectedRegionPlaylist?.id)
        // Removing playlist rows or blocks does not rebuild the audio project.
        if edited.songs == before.songs {
            guard let state = edited.regionSetlist, state != regionSetlist else { return false }
            return configureRegionSetlist(state)
        }
        editProject { $0 = edited }
        if snapshot.project != before, let focusedRegion, current?.parts.contains(where: { $0.id == focusedRegion }) != true { self.focusedRegion = nil }
        return snapshot.project != before
    }

    public init(executor: any CommandExecutor, persistence: any ProjectPersistence, initialProject: Project = .demo(), cursorMemory: ProjectCursorMemory? = nil) throws {
        self.executor = executor; self.persistence = persistence; self.cursorMemory = cursorMemory
        try executor.load(initialProject); snapshot = try executor.snapshot()
        try restoreCursor(); resetHistory()
    }
    public func restore() async {
        do { if let project = try await persistence.load() { try replaceProject(project) } else { try await persistence.save(snapshot.project) } } catch { message = error.localizedDescription }
    }
    public func startClock() {
        guard timer == nil, isPlaying else { return }; lastTime = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    public func tick() {
        let now = ProcessInfo.processInfo.systemUptime; let delta = now - lastTime; lastTime = now
        guard isPlaying else { return }
        let previous = snapshot.transport
        executor.advance(delta)
        do { let update = try executor.playbackSnapshot(); snapshot.transport = update.transport; snapshot.nextSongId = update.nextSongId; focusPreparedRegion(previous: previous); rememberCursor(); if !isPlaying { timer?.invalidate(); timer = nil; onStop() }; audioUpdate(snapshot, audioProjectRevision) } catch { message = error.localizedDescription }
    }
    public func adjustTempo(_ delta: Double) { resetTapTempo(); setTempo((current?.bpm ?? 120) + delta) }
    public func setTempo(_ bpm: Double) {
        guard bpm.isFinite else { return }
        updateTiming(.tempo, value: min(300, max(60, bpm)))
    }
    public func setMeterBeats(_ beats: Int) {
        guard (1...32).contains(beats) else { return }
        updateTiming(.beatsPerBar, value: Double(beats))
    }
    public func setMeterUnit(_ unit: Int) {
        guard TimelineTempo.beatUnits.contains(unit) else { return }
        updateTiming(.beatUnit, value: Double(unit))
    }
    private func updateTiming(_ command: ShowCommand, value: Double) {
        guard canExecute(), !finishing, let index = snapshot.project.songs.firstIndex(where: { $0.id == current?.id }) else { return }
        let song = snapshot.project.songs[index]
        let old = command == .tempo ? song.bpm : Double(command == .beatsPerBar ? song.meterBeats : song.meterUnit)
        guard old != value else { return }
        do {
            tick()
            try executor.execute(command, target: nil, value: value)
            switch command {
            case .tempo:
                snapshot.project.songs[index].followTempo(value)
                let update = try executor.playbackSnapshot()
                snapshot.transport = update.transport; snapshot.nextSongId = update.nextSongId
                if let restoredCursorPosition { self.restoredCursorPosition = restoredCursorPosition * old / value }
                rememberCursor()
            case .beatsPerBar: snapshot.project.songs[index].beatsPerBar = Int(value)
            case .beatUnit: snapshot.project.songs[index].beatUnit = Int(value)
            default: return
            }
            markChanged()
        } catch { message = error.localizedDescription }
    }
    public func send(_ command: ShowCommand, target: UUID? = nil, value: Double = 0) {
        if [.volume, .pan, .mute, .solo, .clipMute].contains(command) {
            sendMixer(command, target: target, value: value)
            return
        }
        // Advance the clock without scheduling one obsolete audio update before
        // applying Stop/Pause/Seek. Publish and render only the final command state.
        if isPlaying {
            let now = ProcessInfo.processInfo.systemUptime
            executor.advance(now - lastTime); lastTime = now
        }
        guard [.pause, .stop, .stopAll, .subStop].contains(command) || (canExecute() && !finishing) else { return }
        do {
            let previous = snapshot.transport
            try executor.execute(command, target: target, value: value)
            if command == .subSeek { revealSubCursor() }
            lastTime = ProcessInfo.processInfo.systemUptime
            let update = try executor.playbackSnapshot(); snapshot.transport = update.transport; snapshot.nextSongId = update.nextSongId
            focusPreparedRegion(previous: previous)
            rememberCursor()
            if isPlaying { startClock() } else { timer?.invalidate(); timer = nil; onStop() }
            audioUpdate(snapshot, audioProjectRevision)
        } catch { message = error.localizedDescription }
    }
    // Scalar mixer edits update the existing native buses and voices in place.
    private func sendMixer(_ command: ShowCommand, target: UUID?, value: Double) {
        guard canExecute(), !finishing else { return }
        do {
            try executor.execute(command, target: target, value: value)
            if target == nil {
                if command == .volume {
                    let gain = min(pow(10, 12.0 / 20), max(0, value))
                    snapshot.project.masterVolume = gain; audioVolume(nil, gain)
                }
                if command == .mute {
                    let muted = !(snapshot.project.masterMute ?? false)
                    snapshot.project.masterMute = muted; audioMute(nil, muted)
                }
            } else if let target {
                for song in snapshot.project.songs.indices {
                    for track in snapshot.project.songs[song].tracks.indices {
                        if command == .clipMute {
                            if let clip = snapshot.project.songs[song].tracks[track].clips.firstIndex(where: { $0.id == target }) {
                                let muted = !(snapshot.project.songs[song].tracks[track].clips[clip].muted ?? false)
                                snapshot.project.songs[song].tracks[track].clips[clip].muted = muted
                                audioClipMute(target, muted)
                            }
                        } else if snapshot.project.songs[song].tracks[track].id == target {
                            switch command {
                            case .volume:
                                let gain = min(pow(10, 12.0 / 20), max(0, value))
                                snapshot.project.songs[song].tracks[track].volume = gain; audioVolume(target, gain)
                            case .pan:
                                let pan = min(1, max(-1, value))
                                snapshot.project.songs[song].tracks[track].pan = pan; audioPan(target, pan)
                            case .mute:
                                snapshot.project.songs[song].tracks[track].mute.toggle()
                                audioMute(target, snapshot.project.songs[song].tracks[track].mute)
                            case .solo:
                                snapshot.project.songs[song].tracks[track].solo.toggle()
                                audioSolo(target, snapshot.project.songs[song].tracks[track].solo)
                            default: break
                            }
                        }
                    }
                }
            }
            markChanged(refreshAudio: false)
        } catch { message = error.localizedDescription }
    }
    /// Update the engine while dragging without decoding all waveforms every pixel.
    public func previewTrackVolume(_ track: UUID?, gain: Double) {
        guard canExecute(), !finishing else { return }
        do { try executor.execute(.volume, target: track, value: gain); audioVolume(track, gain) }
        catch { message = error.localizedDescription }
    }
    public func previewTrackPan(_ track: UUID, pan: Double) {
        guard canExecute(), !finishing else { return }
        let value = min(1, max(-1, pan))
        do { try executor.execute(.pan, target: track, value: value); audioPan(track, value) }
        catch { message = error.localizedDescription }
    }
    public func previewFX(_ track: UUID?, settings: NativeFXSettings) {
        guard canExecute(), !finishing else { return }
        do {
            try settings.validate(); try executor.setFX(track, settings: settings)
            if let track {
                for song in snapshot.project.songs.indices {
                    if let index = snapshot.project.songs[song].tracks.firstIndex(where: { $0.id == track }) { snapshot.project.songs[song].tracks[index].fx = settings }
                }
            } else { snapshot.project.masterFX = settings }
            effectRevision &+= 1; hasUnsavedChanges = true; pendingFXEdit = true
            audioFX(track, settings)
        } catch { message = error.localizedDescription }
    }
    public func commitFX() { guard pendingFXEdit else { return }; pendingFXEdit = false; markChanged(refreshAudio: false) }
    public func clipFXSettings(_ clip: UUID) -> NativeFXSettings {
        if let settings = snapshot.project.songs.lazy.flatMap(\.tracks).flatMap(\.clips).first(where: { $0.id == clip })?.fx { return settings }
        if let defaults = clipFXDefaults[clip] { return defaults }
        let defaults = NativeFXSettings(); clipFXDefaults[clip] = defaults
        return defaults
    }
    public func previewClipFX(_ clip: UUID, settings: NativeFXSettings) {
        guard canExecute(), !finishing else { return }
        for song in snapshot.project.songs.indices {
            for track in snapshot.project.songs[song].tracks.indices where snapshot.project.songs[song].tracks[track].kind == .standard {
                guard let index = snapshot.project.songs[song].tracks[track].clips.firstIndex(where: { $0.id == clip }) else { continue }
                guard (snapshot.project.songs[song].tracks[track].clips[index].fx ?? NativeFXSettings()) != settings else { return }
                do {
                    try settings.validateForClip(); try executor.setClipFX(clip, settings: settings)
                    snapshot.project.songs[song].tracks[track].clips[index].fx = settings
                    effectRevision &+= 1; hasUnsavedChanges = true; pendingFXEdit = true
                    audioClipFX(clip, settings)
                } catch { message = error.localizedDescription }
                return
            }
        }
    }
    public func insertClipFX(_ clip: UUID, effect: String) {
        guard NativeFXSettings.order.dropFirst().contains(effect) else { return }
        var value = clipFXSettings(clip)
        guard !value.inserted.contains(effect) else { return }
        value.inserted.append(effect); value.setEnabled(effect, enabled: true)
        previewClipFX(clip, settings: value); commitFX()
    }
    public func toggleClipFXBypass(_ clip: UUID, effect: String) {
        var value = clipFXSettings(clip)
        guard value.inserted.contains(effect) else { return }
        value.setEnabled(effect, enabled: !value.isEnabled(effect))
        previewClipFX(clip, settings: value); commitFX(); onProjectEdited()
    }
    public func removeClipFX(_ clip: UUID, effect: String) {
        var value = clipFXSettings(clip)
        guard value.inserted.contains(effect) else { return }
        value.inserted.removeAll { $0 == effect }; value.setEnabled(effect, enabled: false)
        value.externalPlugins?.removeAll { $0.effectKey == effect }
        previewClipFX(clip, settings: value); commitFX(); onProjectEdited()
    }
    public func updateClipFX(_ clip: UUID, effect: String, settings: NativeFXSettings) {
        guard NativeFXSettings.order.dropFirst().contains(effect) else { return }
        let current = clipFXSettings(clip)
        var value = current.merging(effect: effect, from: settings)
        if value.isEnabled(effect), !value.inserted.contains(effect) { value.inserted.append(effect) }
        previewClipFX(clip, settings: value)
    }
    public func toggleClipFXAllBypass(_ clip: UUID) {
        guard canExecute(), !finishing else { return }
        for song in snapshot.project.songs.indices {
            for track in snapshot.project.songs[song].tracks.indices where snapshot.project.songs[song].tracks[track].kind == .standard {
                guard let index = snapshot.project.songs[song].tracks[track].clips.firstIndex(where: { $0.id == clip }) else { continue }
                let value = snapshot.project.songs[song].tracks[track].clips[index].fxBypassed != true
                do {
                    try executor.setClipFXBypass(clip, bypassed: value)
                    snapshot.project.songs[song].tracks[track].clips[index].fxBypassed = value
                    effectRevision &+= 1
                    audioClipFXBypass(clip, value); markChanged(refreshAudio: false)
                } catch { message = error.localizedDescription }
                return
            }
        }
    }
    public func setMIDIInput(_ track: UUID, slot: Int) {
        guard canExecute(), !finishing else { return }
        guard let location = trackLocation(track), snapshot.project.songs[location.song].tracks[location.track].midiInput != (slot == 0 ? nil : slot) else { return }
        do {
            try executor.setMIDIInput(track, slot: slot)
            snapshot.project.songs[location.song].tracks[location.track].midiInput = slot == 0 ? nil : slot
            audioMIDIInput(track, slot)
            markChanged(refreshAudio: false)
        }
        catch { message = error.localizedDescription }
    }
    public func fxSettings(_ track: UUID?) -> NativeFXSettings {
        track.flatMap { id in snapshot.project.songs.flatMap(\.tracks).first(where: { $0.id == id })?.fx } ?? (track == nil ? snapshot.project.masterFX : nil) ?? NativeFXSettings()
    }
    public func insertFX(_ track: UUID?, effect: String) {
        guard NativeFXSettings.order.contains(effect) else { return }
        var value = fxSettings(track)
        guard !value.inserted.contains(effect) else { return }
        value.inserted.append(effect)
        value.setEnabled(effect, enabled: true)
        previewFX(track, settings: value); commitFX()
    }
    public func toggleFXBypass(_ track: UUID?, effect: String) {
        var value = fxSettings(track)
        guard value.inserted.contains(effect) else { return }
        value.setEnabled(effect, enabled: !value.isEnabled(effect))
        previewFX(track, settings: value); commitFX(); onProjectEdited()
    }
    public func removeFX(_ track: UUID?, effect: String) {
        var value = fxSettings(track)
        guard value.inserted.contains(effect) else { return }
        value.inserted.removeAll { $0 == effect }; value.setEnabled(effect, enabled: false)
        value.externalPlugins?.removeAll { $0.effectKey == effect }
        previewFX(track, settings: value); commitFX(); onProjectEdited()
    }
    public func reorderFX(_ track: UUID?, effect: String, before target: String?) {
        var value = fxSettings(track)
        guard effect != target, value.inserted.contains(effect), target == nil || value.inserted.contains(target!) else { return }
        value.inserted.removeAll { $0 == effect }
        let index = target.flatMap { value.inserted.firstIndex(of: $0) } ?? value.inserted.count
        value.inserted.insert(effect, at: index)
        previewFX(track, settings: value); commitFX(); onProjectEdited()
    }
    public func updateFX(_ track: UUID?, effect: String, settings: NativeFXSettings) {
        let current = fxSettings(track)
        guard current.inserted.contains(effect) else { return }
        previewFX(track, settings: current.merging(effect: effect, from: settings))
    }
    public func setRecording(_ track: UUID, input: OutputPatch, format: String) {
        guard canExecute(), !finishing else { return }
        guard let location = trackLocation(track) else { return }
        let previous = snapshot.project.songs[location.song].tracks[location.track]
        guard previous.inputPatch != input || previous.recordingFormat != format else { return }
        do {
            try executor.setRecording(track, input: input, format: format)
            snapshot.project.songs[location.song].tracks[location.track].inputPatch = input
            snapshot.project.songs[location.song].tracks[location.track].recordingFormat = format
            markChanged(refreshAudio: false)
        }
        catch { message = error.localizedDescription }
    }
    public func setTimecode(_ track: UUID, settings: TimecodeSettings) {
        guard canExecute(), !finishing else { return }
        guard let location = trackLocation(track), snapshot.project.songs[location.song].tracks[location.track].kind == .timecode,
              snapshot.project.songs[location.song].tracks[location.track].timecode != settings else { return }
        do {
            try settings.validate(); try executor.setTimecode(track, settings: settings)
            snapshot.project.songs[location.song].tracks[location.track].timecode = settings
            for item in snapshot.project.songs[location.song].tracks[location.track].clips.indices {
                snapshot.project.songs[location.song].tracks[location.track].clips[item].name = "TIMECODE"
            }
            markChanged(refreshAudio: false)
        }
        catch { message = error.localizedDescription }
    }
    public func insertAudioTracks(_ tracks: [Track], song: UUID, project: UUID) throws {
        guard canExecute(), !finishing, snapshot.project.id == project,
              let index = snapshot.project.songs.firstIndex(where: { $0.id == song }) else {
            throw ProjectError.invalid("The destination project is no longer available.")
        }
        try executor.insertAudioTracks(tracks, song: song)
        for track in tracks {
            if let destination = snapshot.project.songs[index].tracks.firstIndex(where: { $0.id == track.id }) {
                snapshot.project.songs[index].tracks[destination].clips += track.clips
            } else { snapshot.project.songs[index].tracks.append(track) }
            for clip in track.clips { snapshot.project.songs[index].duration = max(snapshot.project.songs[index].duration, clip.startTime + clip.duration) }
        }
        markChanged()
    }
    public func addRecordedClip(_ clip: AudioClip, track: UUID) {
        do {
            guard let songIndex = snapshot.project.songs.firstIndex(where: { $0.tracks.contains { $0.id == track } }),
                  let trackIndex = snapshot.project.songs[songIndex].tracks.firstIndex(where: { $0.id == track }) else {
                throw ProjectError.invalid("Unknown recording track")
            }
            try executor.addRecordedClip(clip, track: track)
            snapshot.project.songs[songIndex].tracks[trackIndex].clips.append(clip)
            snapshot.project.songs[songIndex].duration = max(snapshot.project.songs[songIndex].duration, clip.startTime + clip.duration)
            markChanged()
        }
        catch { message = "Recording saved, but could not insert item: " + error.localizedDescription }
    }
    @discardableResult public func addTextItem(track: UUID) -> UUID? {
        guard canExecute(), !finishing,
              let song = snapshot.project.songs.firstIndex(where: { $0.id == snapshot.transport.songId }),
              let row = snapshot.project.songs[song].tracks.firstIndex(where: { $0.id == track }),
              snapshot.project.songs[song].tracks[row].kind.isText else { return nil }
        let position = snapshot.transport.editPosition ?? snapshot.transport.position
        guard position.isFinite, position >= 0 else { return nil }
        let kind = snapshot.project.songs[song].tracks[row].kind
        let clip = AudioClip(id: UUID(), name: kind.title, startTime: position, duration: 10, text: "")
        guard snapshot.project.songs[song].tracks[row].canPlaceItem(start: position, duration: clip.duration) else {
            message = "There is already an item at this position on this track."
            return nil
        }
        do {
            try executor.addRecordedClip(clip, track: track)
            snapshot.project.songs[song].tracks[row].clips.append(clip)
            snapshot.project.songs[song].duration = max(snapshot.project.songs[song].duration, position + clip.duration)
            markChanged()
            return clip.id
        } catch { message = error.localizedDescription; return nil }
    }
    @discardableResult public func updateTextItem(_ id: UUID, text: String) -> Bool {
        guard canExecute(), !finishing else { return false }
        do { try AudioClip.validateText(text) }
        catch { message = error.localizedDescription; return false }
        for song in snapshot.project.songs.indices {
            for track in snapshot.project.songs[song].tracks.indices where snapshot.project.songs[song].tracks[track].kind.isText {
                guard let item = snapshot.project.songs[song].tracks[track].clips.firstIndex(where: { $0.id == id }) else { continue }
                do { try AudioClip.validateText(text, maximum: snapshot.project.songs[song].tracks[track].kind.maximumTextLength ?? AudioClip.maximumTextLength) }
                catch { message = error.localizedDescription; return false }
                guard snapshot.project.songs[song].tracks[track].clips[item].text != text else { return true }
                do {
                    try executor.setClipText(id, text: text)
                    // Editing this small field keeps waveform arrays and both clocks
                    // untouched, without encoding the rest of the project.
                    snapshot.project.songs[song].tracks[track].clips[item].text = text
                    markChanged(refreshAudio: false)
                    return true
                } catch { message = error.localizedDescription; return false }
            }
        }
        return false
    }
    public func editTrack(_ id: UUID, name: String, color: UInt32) {
        guard canExecute(), !finishing else { return }
        guard let location = trackLocation(id) else { return }
        let previous = snapshot.project.songs[location.song].tracks[location.track]
        let finalName = previous.fixedName ?? name
        guard previous.name != finalName || previous.color != color else { return }
        do {
            try executor.editTrack(id, name: finalName, color: color)
            snapshot.project.songs[location.song].tracks[location.track].name = finalName
            snapshot.project.songs[location.song].tracks[location.track].color = color
            markChanged(refreshAudio: false); onProjectEdited()
        }
        catch { message = error.localizedDescription }
    }
    public func setTrackRouting(_ ids: Set<UUID>, receive: Bool, slot: Int, other: UUID?) {
        guard slot >= 0 else { return }
        editTrackRouting(ids, receive: receive) { values in
            while values.count <= slot { values.append(nil) }
            values[slot] = other
        }
    }
    public func addTrackRoute(_ ids: Set<UUID>, receive: Bool) {
        editTrackRouting(ids, receive: receive) { $0.append(nil) }
    }
    public func removeTrackRoute(_ ids: Set<UUID>, receive: Bool, slot: Int) {
        editTrackRouting(ids, receive: receive) { if $0.indices.contains(slot) { $0.remove(at: slot) } }
    }
    private func editTrackRouting(_ ids: Set<UUID>, receive: Bool, change: (inout [UUID?]) -> Void) {
        guard canExecute(), !finishing, var song = current else { return }
        var edits: [UUID: TrackRouting] = [:]
        for index in song.tracks.indices where ids.contains(song.tracks[index].id) && song.tracks[index].kind == .standard {
            var routing = song.tracks[index].routing ?? TrackRouting(receives: [], transmitters: [])
            if receive { change(&routing.receives) } else { change(&routing.transmitters) }
            if routing != song.tracks[index].routing { edits[song.tracks[index].id] = routing; song.tracks[index].routing = routing }
        }
        guard !edits.isEmpty else { return }
        do {
            try song.validateTrackRouting(); try executor.setTrackRouting(edits)
            for index in snapshot.project.songs.indices where snapshot.project.songs[index].id == song.id { snapshot.project.songs[index] = song }
            audioRouting(edits); recordEdit(); projectRevision &+= 1; hasUnsavedChanges = true
        } catch { message = error.localizedDescription }
    }
    public func setOutputPatches(track: UUID?, patches: [OutputPatch]) {
        guard canExecute(), !finishing else { return }
        let location = track.flatMap(trackLocation)
        guard track == nil || location != nil else { return }
        let previous = location.map { snapshot.project.songs[$0.song].tracks[$0.track].outputPatches } ?? snapshot.project.masterOutputPatches
        guard previous != patches else { return }
        do {
            for patch in patches { try patch.validate(allowMaster: track != nil, allowGroup: location.map { snapshot.project.songs[$0.song].tracks[$0.track].parentTrackID != nil } ?? false, allowNone: true) }
            if let location {
                var song = snapshot.project.songs[location.song]
                song.tracks[location.track].outputs = patches
                try song.validateTrackRouting()
            }
            try executor.setOutputPatches(track: track, patches: patches)
            if let location {
                snapshot.project.songs[location.song].tracks[location.track].outputs = patches
                snapshot.project.songs[location.song].tracks[location.track].patch = nil
                snapshot.project.songs[location.song].tracks[location.track].secondaryPatch = nil
            } else {
                snapshot.project.masterOutputs = patches
                snapshot.project.masterPatch = nil; snapshot.project.masterSecondaryPatch = nil
            }
            audioPatches(track, patches); recordEdit(); projectRevision &+= 1; hasUnsavedChanges = true
        } catch { message = error.localizedDescription }
    }
    public func setOutputPatch(track: UUID?, patch: OutputPatch, slot: Int = 0) {
        guard canExecute(), !finishing else { return }
        guard slot >= 0 else { return }
        if let row = track.flatMap({ id in current?.tracks.first { $0.id == id } }), row.outputs != nil || slot > 1 {
            var values = row.outputPatches; while values.count <= slot { values.append(.none) }; values[slot] = patch
            setOutputPatches(track: track, patches: values); return
        } else if track == nil && (snapshot.project.masterOutputs != nil || slot > 1) {
            var values = snapshot.project.masterOutputPatches; while values.count <= slot { values.append(.none) }; values[slot] = patch
            setOutputPatches(track: nil, patches: values); return
        }
        let location = track.flatMap(trackLocation)
        guard track == nil || location != nil else { return }
        let previous: OutputPatch
        if let location {
            let row = snapshot.project.songs[location.song].tracks[location.track]
            previous = slot == 0 ? row.primaryOutput : row.secondaryOutput
        } else {
            previous = slot == 0 ? snapshot.project.masterPatch ?? .stereo : snapshot.project.masterSecondaryPatch ?? .none
        }
        guard previous != patch else { return }
        do {
            if let location {
                var song = snapshot.project.songs[location.song]
                if slot == 0 { song.tracks[location.track].patch = patch } else { song.tracks[location.track].secondaryPatch = patch }
                try song.validateTrackRouting()
            }
            try executor.setOutputPatch(track: track, patch: patch, slot: slot)
            if let location {
                if slot == 0 { snapshot.project.songs[location.song].tracks[location.track].patch = patch }
                else { snapshot.project.songs[location.song].tracks[location.track].secondaryPatch = patch }
            } else if slot == 0 { snapshot.project.masterPatch = patch }
            else { snapshot.project.masterSecondaryPatch = patch }
            audioPatch(track, patch, slot)
            markChanged(refreshAudio: false)
        }
        catch { message = error.localizedDescription }
    }
    public func groupTracks(_ ids: Set<UUID>) {
        guard canExecute(), !finishing, ids.count > 1 else { return }
        do { try executor.groupTracks(Array(ids)); snapshot = try executor.snapshot(); markChanged() }
        catch { message = error.localizedDescription }
    }
    public func reorderTrack(_ track: UUID, before: UUID?) {
        guard canExecute(), !finishing, track != before,
              current?.tracks.contains(where: { $0.id == track && $0.kind == .standard }) == true else { return }
        do { try executor.reorderTrack(track, before: before); snapshot = try executor.snapshot(); markChanged() }
        catch { message = error.localizedDescription }
    }
    public static func sequentialInputPatches(count: Int, channels: Int) -> [OutputPatch] {
        guard (1...400).contains(count), channels > 0 else { return [] }
        return (0..<count).map { OutputPatch(firstChannel: $0 % channels + 1, channelCount: 1) }
    }
    @discardableResult public func addTracks(name: String, role: TrackRole, count: Int, inputPatches: [OutputPatch] = [], after selected: UUID? = nil) -> [UUID] {
        guard canExecute(), !finishing, let songIndex = snapshot.project.songs.firstIndex(where: { $0.id == current?.id }) else { return [] }
        let existingCount = snapshot.project.songs.reduce(0) { $0 + $1.tracks.count }
        guard (1...400).contains(count), count <= max(0, 400 - existingCount) else { message = "Maximum of 400 tracks per project."; return [] }
        let kind = TrackKind(rawValue: role.rawValue) ?? .standard
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind != .standard || !trimmed.isEmpty else { message = "Nome da pista"; return [] }
        guard kind == .standard || count == 1 else { message = "Special tracks must be created one at a time."; return [] }
        guard inputPatches.isEmpty || inputPatches.count == count else { message = "Invalid input routing."; return [] }
        if kind == .timecode && snapshot.project.songs.contains(where: { $0.tracks.contains { $0.kind == .timecode } }) {
            message = "A Timecode track already exists."; return []
        }
        var project = snapshot.project
        let existing = project.songs[songIndex].tracks
        let selectedIndex = selected.flatMap { id in existing.firstIndex { $0.id == id } }
        let insertion = kind == .standard ? selectedIndex.map { $0 + 1 } ?? existing.count : existing.count
        let parent: UUID?
        if kind == .standard, let selectedIndex {
            let selected = existing[selectedIndex]
            parent = selected.parentTrackID ?? (existing.contains { $0.parentTrackID == selected.id } ? selected.id : nil)
        } else { parent = nil }
        var newTracks: [Track] = []
        for index in 0..<count {
            let trackName = kind == .standard ? trimmed + (count == 1 ? "" : String(format: " %02d", index + 1)) : kind.title
            var track = Track(id: UUID(), name: trackName, role: role)
            track.parentTrackID = parent
            if kind == .standard && !inputPatches.isEmpty { track.inputPatch = inputPatches[index] }
            if kind == .timecode { track.timecode = TimecodeSettings(); track.patch = OutputPatch.none }
            newTracks.append(track)
        }
        project.songs[songIndex].tracks.insert(contentsOf: newTracks, at: insertion)
        project.orderSpecialTracks()
        do {
            try project.validate()
            tick(); try executor.applyProjectEdit(project)
            snapshot = try executor.snapshot(); markChanged(); onProjectEdited()
            message = ""
            return newTracks.map(\.id)
        } catch { message = error.localizedDescription; return [] }
    }
    @discardableResult public func addTrack(name: String, role: TrackRole, after selected: UUID? = nil) -> UUID? {
        guard canExecute(), !finishing else { return nil }
        let tracks = current?.tracks ?? []
        let before = selected.flatMap { id in tracks.firstIndex(where: { $0.id == id }) }.flatMap { index in
            index + 1 < tracks.count ? tracks[index + 1].id : nil
        }
        let id = UUID()
        do {
            try executor.addTrack(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), role: role)
            if let before { try executor.reorderTrack(id, before: before) }
            snapshot = try executor.snapshot(); markChanged()
            return id
        } catch { message = error.localizedDescription; return nil }
    }
    public func resizeRegion(_ id: UUID, start: Double, end: Double) {
        guard canExecute(), !finishing, let region = current?.parts.first(where: { $0.id == id }),
              region.parentRegionID == nil, current?.parts.contains(where: { $0.parentRegionID == id }) != true else { return }
        do { try executor.resizeRegion(id, start: start, end: end); snapshot = try executor.snapshot(); markChanged() }
        catch { message = error.localizedDescription }
    }
    public func moveRegion(_ id: UUID, start: Double) {
        guard canExecute(), !finishing else { return }
        do { try executor.moveRegion(id, start: start); snapshot = try executor.snapshot(); markChanged() }
        catch { message = error.localizedDescription }
    }
    public var pitchRegion: Part? {
        guard let song = current else { return nil }
        if snapshot.transport.playing {
            if let id = snapshot.transport.ignoreNextRegionId, let current = song.parts.first(where: { $0.id == id }) { return current }
            return song.pitchRegion(at: snapshot.transport.position, fallback: snapshot.transport.regionId)
        }
        guard let selected = song.parts.first(where: { $0.id == focusedRegion }) ?? song.parts.first(where: { $0.id == snapshot.transport.regionId }) else { return nil }
        return song.parts.filter { $0.parentRegionID == selected.id }.min { $0.startTime < $1.startTime } ?? selected
    }
    public func setRegionPitch(_ id: UUID, semitones: Int, tracks: Set<UUID>, groups: Set<UUID>) {
        guard canExecute(), !finishing, (-6...6).contains(semitones),
              let song = snapshot.project.songs.firstIndex(where: { $0.id == snapshot.transport.songId }),
              let region = snapshot.project.songs[song].parts.firstIndex(where: { $0.id == id }) else { return }
        let t = tracks.sorted { $0.uuidString < $1.uuidString }, g = groups.sorted { $0.uuidString < $1.uuidString }
        let previous = snapshot.project.songs[song].parts[region]
        guard previous.semitones != semitones || previous.pitchTrackIDs != t || previous.pitchGroupIDs != g else { return }
        do {
            try executor.setRegionPitch(id, semitones: semitones, tracks: t, groups: g)
            snapshot.project.songs[song].parts[region].pitchSemitones = semitones
            snapshot.project.songs[song].parts[region].pitchTrackIDs = t
            snapshot.project.songs[song].parts[region].pitchGroupIDs = g
            markChanged(refreshAudio: false)
        } catch { message = error.localizedDescription }
    }
    public func editRegion(_ id: UUID, name: String, color: UInt32, uppercaseName: Bool? = nil) {
        guard canExecute(), !finishing,
              let song = snapshot.project.songs.firstIndex(where: { $0.id == snapshot.transport.songId }),
              let region = snapshot.project.songs[song].parts.firstIndex(where: { $0.id == id }) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = snapshot.project.songs[song].parts[region]
        let uppercase = uppercaseName ?? previous.usesUppercase
        guard previous.name != name || previous.color != color || previous.usesUppercase != uppercase else { return }
        do {
            try executor.editRegion(id, name: name, color: color, uppercaseName: uppercase)
            snapshot.project.songs[song].parts[region].uppercaseName = uppercase
            snapshot.project.songs[song].parts[region].name = name
            snapshot.project.songs[song].parts[region].color = color
            markChanged(refreshAudio: false)
        }
        catch { message = error.localizedDescription }
    }
    public func moveClip(_ id: UUID, start: Double, track: UUID?) {
        guard canExecute(), !finishing else { return }
        if let source = current?.tracks.first(where: { $0.clips.contains { $0.id == id } }),
           let clip = source.clips.first(where: { $0.id == id }) {
            guard !source.kind.isSingleLane || track == nil || track == source.id,
                  source.kind == .standard || track == nil || track == source.id else { return }
            guard source.canPlaceItem(start: start, duration: clip.duration, excluding: id) else { return }
        }
        do { try executor.moveClip(id, start: start, track: track); snapshot = try executor.snapshot(); markChanged() }
        catch { message = error.localizedDescription }
    }
    public func deleteManualMarker(_ id: UUID) {
        guard canExecute(), !finishing, let song = snapshot.project.songs.firstIndex(where: { $0.id == snapshot.transport.songId }),
              let marker = snapshot.project.songs[song].markers?.first(where: { $0.id == id }),
              marker.unifiedRegionID == nil, marker.sourceRegionID == nil else { return }
        do {
            try executor.deleteManualMarker(id)
            snapshot.project.songs[song].markers?.removeAll { $0.id == id }
            markChanged(refreshAudio: false)
        } catch { message = error.localizedDescription }
    }
    public func setMarker(_ marker: TimelineMarker) {
        guard canExecute(), !finishing else { return }
        var value = marker
        let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.name = value.unifiedRegionID == nil ? String(name.prefix(TimelineMarker.maximumNameLength)) : name
        guard !value.name.isEmpty else { return }
        do { try executor.setMarker(value); snapshot = try executor.snapshot(); markChanged() }
        catch { message = error.localizedDescription }
    }
    @discardableResult public func unifyRegions(containing id: UUID, name: String) -> Bool {
        guard canExecute(), !finishing else { return false }
        do {
            var project = snapshot.project
            let unified = try project.unifyRegions(containing: id, name: name)
            tick(); try executor.applyProjectEdit(project)
            snapshot = try executor.snapshot(); markChanged(); onProjectEdited()
            focusedRegion = unified; regionFocusRequest = UUID(); message = ""
            return true
        } catch { message = error.localizedDescription; return false }
    }
    @discardableResult public func disunifyRegion(_ id: UUID) -> Bool {
        guard canExecute(), !finishing else { return false }
        do {
            var project = snapshot.project
            let members = try project.disunifyRegion(id)
            tick(); try executor.applyProjectEdit(project)
            snapshot = try executor.snapshot(); markChanged(); onProjectEdited()
            focusedRegion = members.first; regionFocusRequest = UUID(); message = ""
            return true
        } catch { message = error.localizedDescription; return false }
    }
    public func regionsFromSelection(_ ids: Set<UUID>) {
        guard canExecute(), !finishing, let track = current?.tracks.first(where: { $0.kind != .timecode && $0.clips.contains { ids.contains($0.id) } }) else { return }
        let lanes = TrackLanes(track: track).lanes
        let topLane = track.clips.filter { ids.contains($0.id) }.compactMap { lanes[$0.id] }.min() ?? 0
        let clips = track.clips.filter { ids.contains($0.id) && lanes[$0.id] == topLane }.sorted { $0.startTime < $1.startTime }
        do { try executor.regionsFromClips(clips.map(\.id)); snapshot = try executor.snapshot(); markChanged() }
        catch { message = error.localizedDescription }
    }
    public func regionFromClip(_ id: UUID) {
        guard canExecute(), !finishing,
              current?.tracks.contains(where: { $0.kind != .timecode && $0.clips.contains { $0.id == id } }) == true else { return }
        do { try executor.regionFromClip(id); snapshot = try executor.snapshot(); markChanged() }
        catch { message = error.localizedDescription }
    }
    private func rememberCursor() {
        cursorMemory?.remember(project: snapshot.project.id, songID: snapshot.transport.songId,
                               position: snapshot.transport.editPosition ?? snapshot.transport.position)
    }
    private func restoreCursor() throws {
        guard let saved = cursorMemory?.cursor(for: snapshot.project.id),
              let song = snapshot.project.songs.first(where: { $0.id == saved.songID }) else { return }
        if snapshot.transport.songId != song.id { try executor.execute(.select, target: song.id, value: 0) }
        let position = min(song.duration, saved.position)
        try executor.execute(.editSeek, target: nil, value: position)
        let update = try executor.playbackSnapshot()
        snapshot.transport = update.transport; snapshot.nextSongId = update.nextSongId
        restoredCursorPosition = position; focusedRegion = update.transport.regionId
        regionFocusRequest = UUID()
    }
    public func choose(_ song: Song) { send(isPlaying ? .queue : .select, target: song.id) }
    public func finishCurrentSong(_ value: Bool) { finishing = value; executor.finishCurrentSong(value) }
    public func flushProject() async throws {
        guard !saving else { throw ProjectError.invalid("Salvamento em andamento.") }
        prepareForSave()
        saving = true
        defer { saving = false }
        let revision = projectRevision, effects = effectRevision, setlist = setlistRevision
        var project = snapshot.project; project.updatedAt = ISO8601DateFormatter().string(from: Date())
        try await persistence.save(project)
        if projectRevision == revision && effectRevision == effects && setlistRevision == setlist { hasUnsavedChanges = false }
    }
    public func saveForClosing() async throws {
        if hasUnsavedChanges { try await flushProject() }
        guard !hasUnsavedChanges else {
            throw ProjectError.invalid("The project changed while saving. Save again before closing.")
        }
    }
    public func save() async {
        do { try await flushProject(); message = "Projeto salvo." } catch { message = error.localizedDescription }
    }
    private func trackLocation(_ id: UUID) -> (song: Int, track: Int)? {
        for song in snapshot.project.songs.indices {
            if let track = snapshot.project.songs[song].tracks.firstIndex(where: { $0.id == id }) { return (song, track) }
        }
        return nil
    }
    private func markChanged(refreshAudio: Bool = true) {
        recordEdit()
        projectRevision &+= 1
        if refreshAudio { audioProjectRevision &+= 1 }
        hasUnsavedChanges = true
        audioUpdate(snapshot, audioProjectRevision)
    }
    /// Prepare playback after the document has selected its media directory.
    public func preparePlayback() { audioUpdate(snapshot, audioProjectRevision) }
    public func replaceProject(_ project: Project) throws {
        regionNavigationTask?.cancel(); regionNavigationTask = nil
        try project.validate()
        timer?.invalidate(); timer = nil
        try executor.load(project); snapshot = try executor.snapshot()
        projectRevision &+= 1; hasUnsavedChanges = false
        audioProjectRevision &+= 1
        itemClipboard = nil
        focusedRegion = nil; restoredCursorPosition = nil; regionFocusRequest = UUID(); message = ""
        try restoreCursor(); resetHistory()
    }
    public func importProject(_ data: Data) throws {
        let project = try ProjectDocumentCodec.decode(data)
        try executor.load(project); snapshot = try executor.snapshot(); try restoreCursor(); markChanged()
    }
}
