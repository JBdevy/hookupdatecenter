import Foundation
import Combine
/// Coalesce model mutations, publishing only changes used by static controls.
/// Progress views continue to observe the playback samples directly.
@MainActor public final class ShowPresentationObserver: ObservableObject {
    public let objectWillChange = ObservableObjectPublisher()
    private let show: ShowController
    private var state: ShowPresentationState
    private var subscription: AnyCancellable?
    private var pending = false
    public init(show: ShowController) {
        self.show = show; state = show.presentationState
        subscription = show.objectWillChange.sink { [weak self] _ in self?.schedule() }
    }
    private func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            let next = self.show.presentationState
            guard self.state != next else { return }
            self.state = next; self.objectWillChange.send()
        }
    }
}
public struct ShowPresentationState: Equatable {
    let project: UUID
    let projectRevision: UInt64
    let setlistRevision: UInt64
    let transport: TransportState
    let nextSong: UUID?
    let focused: UUID?
    let focusRequest: UUID
    let setlistFocusRequest: UUID
    let navigation: ShowController.SetlistNavigationRequest?
    let pitchRegion: UUID?
    let subRegion: UUID?
    let bpm: Double
    let dirty: Bool
    let saving: Bool
    let message: String
    let notice: String?
    let savedAt: String?
}
/// Geometry and editing commands have a different update rate from playback.
/// Native needles sample the transport independently; advancing them must not
/// construct another grid, its caches, and its state objects on every sample.
@MainActor public final class ShowTimelinePresentationObserver: ObservableObject {
    public let objectWillChange = ObservableObjectPublisher()
    public private(set) var state: ShowTimelinePresentationState
    private let show: ShowController
    private var subscription: AnyCancellable?
    private var pending = false
    public init(show: ShowController) {
        self.show = show; state = show.timelinePresentationState
        subscription = show.objectWillChange.sink { [weak self] _ in self?.schedule() }
    }
    private func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            let next = self.show.timelinePresentationState
            guard self.state != next else { return }
            self.state = next; self.objectWillChange.send()
        }
    }
}
public struct ShowTimelinePresentationState: Equatable {
    let project: UUID
    let revision: UInt64
    let song: UUID?
    let focusRequest: UUID
    let selectedRegion: UUID?
    let editPosition: Double?
    let playing: Bool
    let subPlaying: Bool
    let subCursorVisible: Bool
    let trackSelectionRequest: ShowController.TrackSelectionRequest?
    let trackSelection: Set<UUID>
    let splitRequest: UInt64
    let addTrackRequest: UInt64
}
/// Mixer controls observe project edits, never the 30 Hz playback position.
@MainActor public final class ShowProjectPresentation: ObservableObject {
    public let objectWillChange = ObservableObjectPublisher()
}
@MainActor public final class ShowController: ObservableObject {
    public let projectPresentation = ShowProjectPresentation()
    private weak var cachedPresentationObserver: ShowPresentationObserver?
    /// Static controls share one derivation of playback boundary state. Views
    /// retain the observer; the controller's weak cache avoids a retain cycle.
    public var presentationObserver: ShowPresentationObserver {
        if let observer = cachedPresentationObserver { return observer }
        let observer = ShowPresentationObserver(show: self)
        cachedPresentationObserver = observer
        return observer
    }
    public var timelinePresentationState: ShowTimelinePresentationState {
        let transport = snapshot.transport
        return ShowTimelinePresentationState(project: snapshot.project.id, revision: projectRevision,
            song: transport.songId, focusRequest: regionFocusRequest, selectedRegion: selectedTimelineRegion,
            editPosition: transport.editPosition ?? (isPlaying ? nil : transport.position),
            playing: transport.playing, subPlaying: transport.subPlay.playing, subCursorVisible: subCursorVisible,
            trackSelectionRequest: trackSelectionRequest, trackSelection: mixerTrackSelection,
            splitRequest: splitItemsRequest, addTrackRequest: addTrackRequest)
    }
    public var presentationState: ShowPresentationState {
        var transport = snapshot.transport
        transport.position = 0; transport.editPosition = nil
        transport.subPlay.position = 0; transport.multiLoop?.amount = 0
        return ShowPresentationState(project: snapshot.project.id, projectRevision: projectRevision,
            setlistRevision: setlistRevision, transport: transport, nextSong: snapshot.nextSongId,
            focused: focusedRegion, focusRequest: regionFocusRequest, setlistFocusRequest: setlistFocusRequest,
            navigation: setlistNavigationRequest, pitchRegion: pitchRegion?.id,
            subRegion: current?.sectionRegion(at: snapshot.transport.subPlay.position)?.id,
            bpm: tempoControlBPM, dirty: needsSave, saving: saving, message: message,
            notice: modalNotice, savedAt: lastSavedAt)
    }
    private var updatingPlaybackSnapshot = false
    private var publishingTimelinePlaybackTick = false
    @Published public private(set) var snapshot: ShowSnapshot {
        didSet {
            if timelineFollowPaused {
                let before = oldValue.transport, after = snapshot.transport
                let changedPlayback = before.playing != after.playing || before.subPlay.playing != after.subPlay.playing ||
                    before.songId != after.songId ||
                    (after.playing && before.regionId != after.regionId) ||
                    (after.subPlay.playing && oldValue.project.songs.first(where: { $0.id == before.songId })?.sectionRegion(at: before.subPlay.position)?.id !=
                        snapshot.project.songs.first(where: { $0.id == after.songId })?.sectionRegion(at: after.subPlay.position)?.id)
                if changedPlayback { timelineFollowPaused = false }
            }
            if (!updatingPlaybackSnapshot && oldValue.project != snapshot.project) || oldValue.transport.songId != snapshot.transport.songId {
                projectPresentation.objectWillChange.send()
            }
        }
    }
    @Published public private(set) var focusedRegion: UUID?
    /// A region-band click pauses navigation, independently of setlist selection.
    /// The highlight survives Stop and song transitions; only the pause expires.
    @Published public private(set) var selectedTimelineRegion: UUID?
    @Published public private(set) var timelineFollowPaused = false
    public var timelineZoomPosition: Double {
        if timelineFollowPaused {
            let value = snapshot.transport.editPosition ?? snapshot.transport.position
            return value.isFinite ? max(0, value) : 0
        }
        return snapshot.transport.timelineZoomPosition
    }
    public func selectTimelineRegion(_ id: UUID) {
        guard current?.parts.contains(where: { $0.id == id && $0.parentRegionID == nil }) == true else { return }
        selectedTimelineRegion = id
        timelineFollowPaused = true
    }
    private var selectedSetlistBlock: UUID?
    /// Blocks prepare the next Play without starting or queueing a song on click.
    public func selectSetlistBlock(_ id: UUID?) {
        selectedSetlistBlock = id.flatMap { candidate in listedBlocks.contains { $0.id == candidate } ? candidate : nil }
        if selectedSetlistBlock != nil { regionNavigationTask?.cancel(); regionNavigationTask = nil }
    }
    public private(set) var restoredCursorPosition: Double?
    public private(set) var navigationFocusPosition: Double?
    private var timelineNavigationCache: (revision: UInt64, song: UUID, points: TimelineNavigationPoints)?
    @Published public private(set) var regionFocusRequest = UUID()
    @Published public private(set) var setlistFocusRequest = UUID()
    private var regionNavigationTask: Task<Void, Never>?
    public func stepRegion(_ direction: Int, entries: [SetlistEntry]? = nil, commitAfterDelay: Bool = true) {
        selectedSetlistBlock = nil
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
                self.setlistFocusRequest = UUID()
                return
            }
            self.focusRegion(id)
        }
    }
    public func focusRegion(_ id: UUID) {
        selectedSetlistBlock = nil
        restoredCursorPosition = nil
        navigationFocusPosition = nil
        regionNavigationTask?.cancel(); regionNavigationTask = nil
        guard let region = current?.parts.first(where: { $0.id == id }) else { return }
        if snapshot.transport.playing, let song = current {
            let ignored = song.parts.first { $0.id == snapshot.transport.ignoreNextRegionId }
            let playingID = ignored?.id ?? snapshot.transport.regionId
            let position = ignored?.startTime ?? snapshot.transport.position
            let root = song.playingSetlistRegion(playingID, position: position, expanded: [])
            let displayed = root.flatMap { song.playingSetlistRegion(playingID, position: position, expanded: [$0.id]) }
            if id == root?.id || id == displayed?.id {
                // Selecting the song already playing changes only the highlight.
                focusedRegion = id; setlistFocusRequest = UUID()
                return
            }
        }
        if snapshot.transport.playing, let parent = region.parentRegionID,
           let active = current?.parts.first(where: { $0.id == snapshot.transport.regionId }),
           active.id == parent || active.parentRegionID == parent {
            message = "Cannot queue a song from the active unified region"
            return
        }
        let queueing = snapshot.transport.playing
        send(queueing ? .queueRegion : .selectRegion, target: region.id)
        focusedRegion = id
        // Queue selection reveals only the setlist row. The grid keeps following
        // the current transport (or Sub Play) until the queued song takes over.
        if queueing { setlistFocusRequest = UUID() }
        else { regionFocusRequest = UUID() }
    }
    public func searchRegions(_ query: String, byRegionID: Bool = false) -> [Part] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = byRegionID && !term.isEmpty && term.allSatisfy(\.isNumber) ? Int(term) : nil
        return (current?.parts ?? []).enumerated().filter { index, region in
            term.isEmpty || region.name.localizedStandardContains(term) || number == index + 1
        }.map(\.element).sorted { $0.startTime < $1.startTime }
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
    public func setBlockSymbols(_ ids: Set<UUID>, enabled: Bool) {
        var state = regionSetlist
        let allowed = Set(listedBlocks.map(\.id)).intersection(ids)
        guard !allowed.isEmpty, var blocks = state.blocks else { return }
        var changed = false
        for index in blocks.indices where allowed.contains(blocks[index].id) {
            if blocks[index].showsSymbol != enabled { blocks[index].symbol = enabled; changed = true }
        }
        guard changed else { return }
        state.blocks = blocks
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
    public func createRegionPlaylist(name: String, selected: [UUID]) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !selected.isEmpty, let song = current else { return false }
        let available = Set(allRegions.map(\.id))
        var seen = Set<UUID>()
        let ids = selected.filter { available.contains($0) && seen.insert($0).inserted }
        guard !ids.isEmpty else { return false }
        var state = regionSetlist
        let list = RegionPlaylist(id: UUID(), name: name, songId: song.id, regionIds: ids)
        state.playlists.append(list); state.selectedId = list.id
        return configureRegionSetlist(state)
    }
    @discardableResult public func addRegionsToPlaylist(_ id: UUID, selected: [UUID]) -> Bool {
        var state = regionSetlist
        guard let song = current, let index = state.playlists.firstIndex(where: { $0.id == id && $0.songId == song.id }) else { return false }
        let available = Set(allRegions.map(\.id))
        var existing = Set(state.playlists[index].regionIds)
        let additions = selected.filter { available.contains($0) && existing.insert($0).inserted }
        guard !additions.isEmpty else { return false }
        state.playlists[index].regionIds.append(contentsOf: additions)
        return configureRegionSetlist(state)
    }
    @discardableResult public func renameRegionPlaylist(_ id: UUID, name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        var state = regionSetlist
        guard let index = state.playlists.firstIndex(where: { $0.id == id && $0.songId == current?.id }) else { return false }
        guard state.playlists[index].name != name else { return true }
        state.playlists[index].name = name
        return configureRegionSetlist(state)
    }
    public func cloneRegionPlaylist(_ id: UUID) {
        guard regionSetlist.playlists.contains(where: { $0.id == id && $0.songId == current?.id }) else { return }
        var state = regionSetlist
        guard state.clonePlaylist(id) != nil else { return }
        _ = configureRegionSetlist(state)
    }
    public func deleteRegionPlaylist(_ id: UUID) {
        guard regionSetlist.playlists.contains(where: { $0.id == id && $0.songId == current?.id }) else { return }
        var state = regionSetlist
        guard state.deletePlaylist(id) else { return }
        _ = configureRegionSetlist(state)
    }
    public func selectRegionPlaylist(_ id: UUID?) {
        selectedSetlistBlock = nil
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
        navigationFocusPosition = nil
        focusedRegion = queued; regionFocusRequest = UUID()
    }
    private func focusTimelineRegion(at position: Double, preferredRegion: UUID? = nil, forceReveal: Bool = false) {
        guard let song = current else { return }
        let preferred = preferredRegion.flatMap { id in song.parts.first(where: { $0.id == id && position >= $0.startTime && position < $0.endTime }) }
        guard let active = preferred ?? song.parts.filter({
            $0.parentRegionID == nil && position >= $0.startTime && position < $0.endTime
        }).min(by: { $0.endTime - $0.startTime < $1.endTime - $1.startTime }) else {
            regionNavigationTask?.cancel(); regionNavigationTask = nil
            focusedRegion = nil
            return
        }
        let root = active.parentRegionID ?? active.id
        let region = song.playingSetlistRegion(active.id, position: position, expanded: [root]) ?? active
        var changedPlaylist = false
        if let playlist = selectedRegionPlaylist, !playlist.regionIds.contains(root) {
            var state = regionSetlist; state.selectedId = nil
            guard configureRegionSetlist(state) else { return }
            changedPlaylist = true
        }
        // Cursor gestures only reveal a row; they never seek playback or queue it.
        regionNavigationTask?.cancel(); regionNavigationTask = nil
        guard forceReveal || changedPlaylist || focusedRegion != region.id else { return }
        focusedRegion = region.id; setlistFocusRequest = UUID()
    }
    public func setAutomaticSubplay(_ enabled: Bool, seconds: Double? = nil) {
        var state = regionSetlist; state.automaticSubplay = enabled
        if let seconds, seconds.isFinite { state.automaticSubplaySeconds = min(5, max(1, seconds)) }
        _ = configureRegionSetlist(state)
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
    @Published public var modalNotice: String?
    @Published public private(set) var lastSavedAt: String?
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
    @Published public private(set) var mixerTrackSelection: Set<UUID> = [] {
        didSet { if oldValue != mixerTrackSelection { projectPresentation.objectWillChange.send() } }
    }
    public func setMixerTrackSelection(_ ids: Set<UUID>, anchor: UUID?) {
        let valid = ids.intersection((current?.tracks ?? []).filter { $0.kind == .standard }.map(\.id))
        selectedTrackForActions = anchor.flatMap { valid.contains($0) ? $0 : nil } ?? valid.first
        if mixerTrackSelection != valid { mixerTrackSelection = valid }
    }

    public struct SetlistNavigationRequest: Equatable {
        public let id: UUID
        public let direction: Int
    }
    @Published public private(set) var setlistNavigationRequest: SetlistNavigationRequest?
    @Published public private(set) var splitItemsRequest: UInt64 = 0
    @Published public private(set) var normalizeItemsRequest: UInt64 = 0
    @Published public var detectBPMRegion: UUID?
    @Published public var detectBPMRegions: [UUID] = []
    @Published public private(set) var tempoMarkerRequest: UInt64 = 0
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
            if let track {
                setMixerTrackSelection([track.id], anchor: track.id)
                trackSelectionRequest = TrackSelectionRequest(id: UUID(), track: track.id)
            }
        case .muteTrack: send(.mute, target: track?.id)
        case .soloTrack: send(.solo, target: track?.id)
        case .muteMaster: send(.mute)
        case .soloMaster: send(.solo)
        case .volumeMaster:
            if let midiValue { send(.volume, value: MIDIFaderValue.gain(midiValue)) }
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
        case .toggleMultiLoopBypass: send(.toggleMultiLoopBypass)
        case .subPlayStop: send(snapshot.transport.subPlay.playing ? .subStop : .subPlay)
        case .addTrack: addTrackRequest &+= 1
        case .setlistUp, .setlistDown: setlistNavigationRequest = SetlistNavigationRequest(id: UUID(), direction: action == .setlistUp ? -1 : 1)
        case .toggleAuto: toggleRegionAuto()
        case .ignoreNext: send(.ignoreNext)
        case .splitItems: splitItemsRequest &+= 1
        case .normalizeItems: normalizeItemsRequest &+= 1
        case .createTempoMarker: tempoMarkerRequest &+= 1
        case .toggleVideo: toggleVideoWindow()
        case .toggleTeleprompter: toggleTeleprompterWindow()
        case .toggleTracks: toggleTracksPanel()
        case .toggleSetlist: toggleSetlistPanel()
        case .projectStart, .projectEnd, .nextRegion, .previousRegion, .nextTimelinePoint, .previousTimelinePoint:
            guard let song = current else { return }
            if timelineNavigationCache?.revision != projectRevision || timelineNavigationCache?.song != song.id {
                timelineNavigationCache = (projectRevision, song.id, TimelineNavigationPoints(song: song))
            }
            let position = snapshot.transport.editPosition ?? snapshot.transport.position
            guard let target = timelineNavigationCache?.points.target(for: action, position: position) else { return }
            send(.editSeek, value: target)
            guard abs((snapshot.transport.editPosition ?? snapshot.transport.position) - target) < 0.0000001 else { return }
            navigationFocusPosition = target
            regionFocusRequest = UUID()
        }
    }
    public var isPlaying: Bool { snapshot.transport.playing || snapshot.transport.subPlay.playing }
    public var canExecute: () -> Bool = { true }
    public var onStop: () -> Void = {}
    public var toggleVideoWindow: () -> Void = {}
    public var toggleTeleprompterWindow: () -> Void = {}
    public var toggleTracksPanel: () -> Void = {}
    public var toggleSetlistPanel: () -> Void = {}
    public var onSetlistEdited: () -> Void = {}
    public var audioUpdate: (ShowSnapshot, UInt64) -> Void = { _, _ in }
    public var audioFX: (UUID?, NativeFXSettings) -> Void = { _, _ in }
    public var audioClipFX: (UUID, NativeFXSettings) -> Void = { _, _ in }
    public var audioClipFXBypass: (UUID, Bool) -> Void = { _, _ in }
    private var clipFXDefaults: [UUID: NativeFXSettings] = [:]
    public private(set) var mixerPlaybackRevision: UInt64 = 0
    private var applyingLoopMixer = false
    private var loopMixerChanged = false
    private var loopMixerProject: Project?
    private struct LoopMixerBase { var volume: Double; var mute: Bool; var solo: Bool }
    private var loopMixerBase: [UUID: LoopMixerBase] = [:]
    private var loopMixerID: UUID?
    private var loopGainPlan = MultiLoopGainPlan()
    private var loopGainPlanKey: (project: UUID, song: UUID?, revision: UInt64, rules: [MultiLoopTrack])?
    private var loopMixerTrackLocations: [UUID: (song: Int, track: Int)] = [:]
    private var loopMixerTrackLocationsKey: (project: UUID, revision: UInt64)?
    #if DEBUG
    // Deterministic scalability checks without timing noise or release overhead.
    private(set) var loopMixerLookupWork = (indexedTracks: 0, lookups: 0)
    #endif
    private func resetLoopMixer() {
        loopMixerBase.removeAll(); loopMixerID = nil
        loopGainPlan = MultiLoopGainPlan(); loopGainPlanKey = nil
        loopMixerTrackLocations.removeAll(); loopMixerTrackLocationsKey = nil
    }
    private func applyLoopMixer() {
        guard !applyingLoopMixer else { return }
        let loop = snapshot.transport.multiLoop
        guard loop != nil || loopMixerID != nil || !loopMixerBase.isEmpty else { return }
        if loopMixerTrackLocationsKey?.project != snapshot.project.id || loopMixerTrackLocationsKey?.revision != projectRevision {
            loopMixerTrackLocations.removeAll(keepingCapacity: true)
            for (song, row) in snapshot.project.songs.enumerated() {
                for (track, value) in row.tracks.enumerated() {
                    loopMixerTrackLocations[value.id] = (song, track)
                    #if DEBUG
                    loopMixerLookupWork.indexedTracks += 1
                    #endif
                }
            }
            loopMixerTrackLocationsKey = (snapshot.project.id, projectRevision)
        }
        let previousLegacyTargets = loopGainPlan.legacyVolumeTargets
        let loopRules = loop?.tracks ?? []
        if loopGainPlanKey?.project != snapshot.project.id || loopGainPlanKey?.song != snapshot.transport.songId ||
            loopGainPlanKey?.revision != projectRevision || loopGainPlanKey?.rules != loopRules {
            loopGainPlan = MultiLoopGainPlan(loop: loop, tracks: current?.tracks ?? [])
            loopGainPlanKey = (snapshot.project.id, snapshot.transport.songId, projectRevision, loopRules)
        }
        applyingLoopMixer = true
        loopMixerChanged = false
        loopMixerProject = snapshot.project
        // M/S remains visible and uses ordinary mixer commands. Gain envelopes
        // run in the audio engine; only conflicting linked rules move faders.
        defer {
            let project = loopMixerProject
            loopMixerProject = nil; applyingLoopMixer = false
            if loopMixerChanged, let project { snapshot.project = project }
        }
        let rules = Dictionary(uniqueKeysWithValues: (loop?.tracks ?? []).map { ($0.id, $0) })
        func values(_ id: UUID) -> LoopMixerBase? {
            let project = loopMixerProject ?? snapshot.project
            if id == MultiLoopTrack.masterID {
                return LoopMixerBase(volume: project.masterVolume ?? 1, mute: project.masterMute ?? false, solo: project.masterSolo ?? false)
            }
            #if DEBUG
            loopMixerLookupWork.lookups += 1
            #endif
            guard let location = loopMixerTrackLocations[id] else { return nil }
            // Cache positions, never scalar values: earlier M/S or linked edits
            // in this same frame must be visible to the following rule.
            let track = project.songs[location.song].tracks[location.track]
            return LoopMixerBase(volume: track.volume, mute: track.mute, solo: track.solo)
        }
        func apply(_ id: UUID, _ value: LoopMixerBase, volume: Bool) {
            guard let now = values(id) else { return }
            let target: UUID? = id == MultiLoopTrack.masterID ? nil : id
            if volume && abs(now.volume - value.volume) > 0.000001 { sendMixer(.volume, target: target, value: value.volume) }
            if now.mute != value.mute { sendMixer(.mute, target: target, value: 0) }
            if now.solo != value.solo { sendMixer(.solo, target: target, value: 0) }
        }
        if loop?.id != loopMixerID {
            for (id, base) in loopMixerBase { apply(id, base, volume: previousLegacyTargets.contains(id)) }
            loopMixerBase.removeAll(); loopMixerID = loop?.id
        } else {
            for id in previousLegacyTargets.subtracting(loopGainPlan.legacyVolumeTargets) {
                if let base = loopMixerBase[id], let now = values(id), abs(now.volume - base.volume) > 0.000001 {
                    sendMixer(.volume, target: id == MultiLoopTrack.masterID ? nil : id, value: base.volume)
                }
            }
        }
        for id in Set(loopMixerBase.keys).union(rules.keys) {
            guard var base = loopMixerBase[id] ?? values(id) else { continue }
            // Internal envelopes leave the manual fader untouched, so edits
            // made through any gesture remain the base if this rule later
            // switches to the legacy linked-fader path.
            if !previousLegacyTargets.contains(id), let now = values(id) { base.volume = now.volume }
            if rules[id] != nil { loopMixerBase[id] = base }
            let rule = rules[id]
            let desired = LoopMixerBase(volume: loop?.gain(base.volume, rule: rule) ?? base.volume,
                mute: base.mute || (loop?.gates == true && rule?.mute == true),
                solo: base.solo || (loop?.gates == true && rule?.solo == true))
            apply(id, desired, volume: loopGainPlan.legacyVolumeTargets.contains(id))
            if rule == nil { loopMixerBase[id] = nil }
        }
    }
    private var effectRevision: UInt64 = 0
    private var pendingFXEdit = false
    public private(set) var setlistRevision: UInt64 = 0
    public var audioItemChannelMode: (UUID, Int) -> Void = { _, _ in }
    public var audioItemNormalization: (UUID, Double) -> Void = { _, _ in }
    public var audioItemFade: (UUID, Bool, Double) -> Void = { _, _, _ in }
    public var audioItemPhase: (UUID, Bool) -> Void = { _, _ in }
    public var audioItemPan: (UUID, Double) -> Void = { _, _ in }
    public var audioItemGain: (UUID, Double) -> Void = { _, _ in }
    public var audioVolume: (UUID?, Double) -> Void = { _, _ in }
    public var audioPan: (UUID, Double) -> Void = { _, _ in }
    public var audioMute: (UUID?, Bool) -> Void = { _, _ in }
    public var audioSolo: (UUID, Bool) -> Void = { _, _ in }
    public var audioPhase: (UUID?, Bool) -> Void = { _,_ in }
    public var audioMasterMono: (Bool) -> Void = { _ in }
    public var audioMasterSolo: (Bool) -> Void = { _ in }
    public var audioClipMute: (UUID, Bool) -> Void = { _, _ in }
    public var prepareForSave: () -> Void = {}
    public var audioRouting: ([UUID: TrackRouting]) -> Void = { _ in }
    public var audioPatches: (UUID?, [OutputPatch]) -> Void = { _, _ in }
    public var audioPatch: (UUID?, OutputPatch, Int) -> Void = { _, _, _ in }
    public var audioMIDIChannel: (UUID, Int) -> Void = { _, _ in }
    public var audioMIDIInput: (UUID, Int) -> Void = { _, _ in }
    private let executor: any CommandExecutor, persistence: any ProjectPersistence
    private let cursorMemory: ProjectCursorMemory?
    private let globalDefaults: UserDefaults?
    public static let multiLoopBypassDefaultsKey = "catlive.multiLoopsBypassed"
    private func restoreGlobalBypass() throws {
        guard let globalDefaults else { return }
        let requested = globalDefaults.bool(forKey: Self.multiLoopBypassDefaultsKey)
        if (snapshot.transport.multiLoopsBypassed == true) != requested {
            try executor.execute(.toggleMultiLoopBypass, target: nil, value: 0)
            snapshot.transport = try executor.playbackSnapshot().transport
        }
    }
    private var timer: Timer?, lastTime = ProcessInfo.processInfo.systemUptime
    @Published public private(set) var hasUnsavedChanges = false
    private var lastSavedCursor: SavedProjectCursor?
    private var editingCursor: SavedProjectCursor? {
        guard let songID = snapshot.transport.songId else { return nil }
        return SavedProjectCursor(songID: songID, position: snapshot.transport.editPosition ?? snapshot.transport.position)
    }
    /// Navigation enables an explicit Save without making closing require a content-save prompt.
    public var needsSave: Bool { hasUnsavedChanges || editingCursor != lastSavedCursor }
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
    private func recordEdit(preservingMediaStorage: Bool = false) {
        history?.record(snapshot.project, preservingMediaStorage: preservingMediaStorage)
        canUndo = history?.canUndo == true; canRedo = history?.canRedo == true
        if !preservingMediaStorage { knownMediaPaths.formUnion(snapshot.project.mediaPaths) }
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
    @discardableResult public func replaceRenderedItem(_ rendered: AudioClip, original: AudioClip, track: UUID, project: UUID) -> Bool {
        guard canExecute(), !finishing, snapshot.project.id == project else { return false }
        for song in snapshot.project.songs.indices {
            guard let channel = snapshot.project.songs[song].tracks.firstIndex(where: { $0.id == track }),
                  let item = snapshot.project.songs[song].tracks[channel].clips.firstIndex(where: { $0.id == original.id }),
                  snapshot.project.songs[song].tracks[channel].clips[item] == original else { continue }
            do {
                var rendered = rendered
                rendered.regionOwnerID = rendered.startTime == original.startTime ? original.regionOwnerID : snapshot.project.songs[song].regionOwner(at: rendered.startTime)
                if original.isProjectionMedia && snapshot.project.songs[song].tracks[channel].kind != .standard {
                    var next = snapshot.project
                    next.songs[song].tracks[channel].clips.remove(at: item)
                    var audioTrack = Track(id: UUID(), name: rendered.name, role: .other, color: next.songs[song].tracks[channel].color)
                    audioTrack.clips = [rendered]
                    next.songs[song].tracks.insert(audioTrack, at: channel + 1)
                    next.orderSpecialTracks()
                    try executor.applyProjectEdit(next)
                    snapshot = try executor.snapshot()
                    markChanged(); onProjectEdited(); return true
                }
                try executor.replaceAudioClip(rendered, track: track)
                snapshot.project.songs[song].tracks[channel].clips[item] = rendered
                markChanged(); onProjectEdited(); return true
            } catch { message = error.localizedDescription; return false }
        }
        message = "The audio item changed during Re-render."; return false
    }
    @discardableResult public func replaceGluedItems(_ replacements: [GluedItemReplacement], project: UUID, song: UUID) -> Bool {
        guard canExecute(), !finishing, snapshot.project.id == project, current?.id == song, !replacements.isEmpty,
              Set(replacements.map(\.track)).count == replacements.count,
              let index = snapshot.project.songs.firstIndex(where: { $0.id == song }) else { return false }
        var next = snapshot.project
        for replacement in replacements {
            guard let channel = next.songs[index].tracks.firstIndex(where: { $0.id == replacement.track }),
                  next.songs[index].tracks[channel].kind == .standard, !replacement.originals.isEmpty,
                  Set(replacement.originals.map(\.id)).count == replacement.originals.count,
                  replacement.originals.allSatisfy({ original in next.songs[index].tracks[channel].clips.contains(original) }) else {
                message = "The selected items changed while unifying."; return false
            }
            let ids = Set(replacement.originals.map(\.id))
            next.songs[index].tracks[channel].clips.removeAll { ids.contains($0.id) }
            next.songs[index].tracks[channel].clips.append(replacement.rendered)
            next.songs[index].tracks[channel].clips.sort { $0.startTime < $1.startTime }
        }
        do {
            try next.validate()
            tick(); try executor.applyProjectEdit(next)
            snapshot = try executor.snapshot(); markChanged(); onProjectEdited(); message = ""
            return true
        } catch { message = error.localizedDescription; return false }
    }
    public func previewItemFade(_ id: UUID, fadeIn: Bool, seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        audioItemFade(id, fadeIn, seconds)
    }
    public func setItemFade(_ id: UUID, fadeIn: Bool, seconds: Double) {
        guard canExecute(), !finishing, seconds.isFinite, seconds >= 0 else { return }
        for song in snapshot.project.songs.indices {
            for track in snapshot.project.songs[song].tracks.indices where snapshot.project.songs[song].tracks[track].kind == .standard {
                guard let index = snapshot.project.songs[song].tracks[track].clips.firstIndex(where: { $0.id == id }) else { continue }
                let clip = snapshot.project.songs[song].tracks[track].clips[index]
                let value = min(clip.duration, seconds)
                let previous = (fadeIn ? clip.fadeIn : clip.fadeOut) ?? 0
                guard previous != value else { return }
                do {
                    try executor.execute(fadeIn ? .clipFadeIn : .clipFadeOut, target: id, value: value)
                    if fadeIn { snapshot.project.songs[song].tracks[track].clips[index].fadeIn = value == 0 ? nil : value }
                    else { snapshot.project.songs[song].tracks[track].clips[index].fadeOut = value == 0 ? nil : value }
                    audioItemFade(id, fadeIn, value)
                    markChanged(refreshAudio: false)
                } catch { audioItemFade(id, fadeIn, previous); message = error.localizedDescription }
                return
            }
        }
    }
    public func setItemPitch(_ id: UUID, semitones: Double) {
        guard canExecute(), !finishing, (-12...12).contains(semitones) else { return }
        for song in snapshot.project.songs.indices {
            for track in snapshot.project.songs[song].tracks.indices where snapshot.project.songs[song].tracks[track].kind == .standard {
                guard let item = snapshot.project.songs[song].tracks[track].clips.firstIndex(where: { $0.id == id && $0.midi == nil }) else { continue }
                guard (snapshot.project.songs[song].tracks[track].clips[item].pitchSemitones ?? 0) != semitones else { return }
                do {
                    try executor.execute(.clipPitch, target: id, value: Double(semitones))
                    snapshot.project.songs[song].tracks[track].clips[item].pitchSemitones = semitones == 0 ? nil : semitones
                    markChanged()
                } catch { message = error.localizedDescription }
                return
            }
        }
    }
    public func toggleItemPhase(_ id: UUID) {
        guard let clip = current?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else { return }
        setItemMix(id, command: .clipPhase, value: clip.phaseInverted == true ? 0 : 1)
    }
    public func previewItemPan(_ id: UUID, pan: Double) {
        guard pan.isFinite else { return }
        audioItemPan(id, min(1, max(-1, pan)))
    }
    public func setItemPan(_ id: UUID, pan: Double) {
        guard pan.isFinite else { return }
        setItemMix(id, command: .clipPan, value: min(1, max(-1, pan)))
    }
    private func setItemMix(_ id: UUID, command: ShowCommand, value: Double) {
        guard canExecute(), !finishing else { return }
        for song in snapshot.project.songs.indices {
            for track in snapshot.project.songs[song].tracks.indices {
                guard let index = snapshot.project.songs[song].tracks[track].clips.firstIndex(where: { $0.id == id }) else { continue }
                let clip = snapshot.project.songs[song].tracks[track].clips[index]
                let previous = command == .clipPan ? clip.pan ?? 0 : clip.phaseInverted == true ? 1.0 : 0.0
                guard previous != value else { return }
                do {
                    tick()
                    try executor.execute(command, target: id, value: value)
                    if command == .clipPan {
                        snapshot.project.songs[song].tracks[track].clips[index].pan = value == 0 ? nil : value
                        audioItemPan(id, value)
                    } else {
                        snapshot.project.songs[song].tracks[track].clips[index].phaseInverted = value != 0
                        audioItemPhase(id, value != 0)
                    }
                    markChanged(refreshAudio: false)
                } catch { message = error.localizedDescription }
                return
            }
        }
    }
    public func previewItemGain(_ id: UUID, gain: Double) { audioItemGain(id, gain) }
    public func setItemGain(_ id: UUID, gain: Double) {
        guard canExecute(), !finishing, gain.isFinite, gain >= 0 else { return }
        let value = min(pow(10, 24.0 / 20), gain)
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
                        edits.append((song, track, item, clip.id, clip.normalizationGain ?? 1, min(pow(10, 24.0 / 20), gain)))
                    }
                }
            }
        }
        guard edits.count == gains.count else { return false }
        var applied = 0
        do {
            for edit in edits { try executor.execute(.clipNormalization, target: edit.id, value: edit.gain); applied += 1 }
            for edit in edits {
                snapshot.project.songs[edit.song].tracks[edit.track].clips[edit.item].normalizationGain = edit.gain == 1 ? nil : edit.gain
                audioItemNormalization(edit.id, edit.gain)
            }
            if edits.contains(where: { $0.gain != $0.old }) { markChanged(refreshAudio: false) }
            return true
        } catch {
            for edit in edits.prefix(applied) { try? executor.execute(.clipNormalization, target: edit.id, value: edit.old) }
            message = error.localizedDescription
            return false
        }
    }
    @discardableResult public func convertItems(_ ids: Set<UUID>, mode: Int) -> Bool {
        guard canExecute(), !finishing, (0...3).contains(mode), !ids.isEmpty else { return false }
        var edits: [(song: Int, track: Int, item: Int, id: UUID, old: Int, gain: Int)] = []
        for song in snapshot.project.songs.indices {
            for track in snapshot.project.songs[song].tracks.indices where snapshot.project.songs[song].tracks[track].kind == .standard {
                for item in snapshot.project.songs[song].tracks[track].clips.indices {
                    let clip = snapshot.project.songs[song].tracks[track].clips[item]
                    if ids.contains(clip.id) {
                        edits.append((song, track, item, clip.id, clip.channelMode ?? 0, mode))
                    }
                }
            }
        }
        guard edits.count == ids.count else { return false }
        var applied = 0
        do {
            for edit in edits { try executor.execute(.clipChannelMode, target: edit.id, value: Double(edit.gain)); applied += 1 }
            for edit in edits {
                snapshot.project.songs[edit.song].tracks[edit.track].clips[edit.item].channelMode = edit.gain == 0 ? nil : edit.gain
                audioItemChannelMode(edit.id, edit.gain)
            }
            if edits.contains(where: { $0.gain != $0.old }) { markChanged(refreshAudio: false) }
            return true
        } catch {
            for edit in edits.prefix(applied) { try? executor.execute(.clipChannelMode, target: edit.id, value: Double(edit.old)) }
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
    public func removeTrackFromGroup(_ id: UUID) { editProject { $0.removeTrackFromGroup(id) } }
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

    public init(executor: any CommandExecutor, persistence: any ProjectPersistence, initialProject: Project = .demo(), cursorMemory: ProjectCursorMemory? = nil, globalDefaults: UserDefaults? = nil) throws {
        self.executor = executor; self.persistence = persistence; self.cursorMemory = cursorMemory; self.globalDefaults = globalDefaults
        var initialProject = initialProject; initialProject.promoteLoopSectionMarkers()
        try executor.load(initialProject); snapshot = try executor.snapshot()
        lastSavedCursor = initialProject.savedCursor
        try restoreGlobalBypass(); try restoreCursor(); resetHistory()
    }
    public func restore() async {
        do { if let project = try await persistence.load() { try replaceProject(project) } else { try await persistence.save(snapshot.project) } } catch { message = error.localizedDescription }
    }
    public func startClock() {
        guard timer == nil, isPlaying else { return }; lastTime = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    /// Presentation can draw between the engine's 30 Hz samples without advancing
    /// transport, decoding another snapshot, or scheduling another audio update.
    public var timelinePlaybackSampleTime: Double { lastTime }
    /// Read synchronously from snapshot publication to distinguish a complete
    /// engine tick, including automated mixer updates, from explicit commands.
    var timelinePlaybackIsPublishingTick: Bool { publishingTimelinePlaybackTick }
    public func tick() {
        let now = ProcessInfo.processInfo.systemUptime; let delta = now - lastTime; lastTime = now
        guard isPlaying else { return }
        let wasPublishing = publishingTimelinePlaybackTick
        publishingTimelinePlaybackTick = true
        defer { publishingTimelinePlaybackTick = wasPublishing }
        let previous = snapshot.transport
        executor.advance(delta)
        do {
            let update = try executor.playbackSnapshot()
            var next = snapshot
            next.transport = update.transport; next.nextSongId = update.nextSongId
            updatingPlaybackSnapshot = true
            snapshot = next
            updatingPlaybackSnapshot = false
            applyLoopMixer(); focusPreparedRegion(previous: previous); rememberCursor()
            if !isPlaying { timer?.invalidate(); timer = nil; onStop() }
            audioUpdate(snapshot, audioProjectRevision)
        } catch { message = error.localizedDescription }
    }
    private var tempoControlRegion: Part? {
        guard let song = current else { return nil }
        if snapshot.transport.playing { return song.sectionRegion(at: snapshot.transport.position) }
        return song.parts.first { $0.id == (focusedRegion ?? snapshot.transport.regionId) }
    }
    private var tempoControlPosition: Double {
        let position = snapshot.transport.playing ? snapshot.transport.position : snapshot.transport.editPosition ?? snapshot.transport.position
        if let region = tempoControlRegion, position < region.startTime || position >= region.endTime { return region.startTime }
        return position
    }
    public var tempoControlBPM: Double { current?.tempoSection(at: tempoControlPosition).bpm ?? 120 }
    public func adjustTempo(_ delta: Double) {
        guard delta.isFinite else { return }
        resetTapTempo()
        setTempo(tempoControlBPM + delta)
    }
    /// Apply one additive change to every tempo inside the selected song.
    /// The end boundary retains the following song's tempo; retiming runs once.
    private func adjustRegionTempo(_ requestedDelta: Double, region: Part) {
        guard canExecute(), !finishing, let index = snapshot.project.songs.firstIndex(where: { $0.id == current?.id }) else { return }
        let before = snapshot.project.songs[index]
        var targets = (before.markers ?? []).filter { $0.isTempo && $0.position >= region.startTime && $0.position < region.endTime }
        func boundary(_ position: Double) -> TimelineMarker {
            let section = before.tempoSection(at: position)
            let active = before.activeTempoMarker(at: position)
            return TimelineMarker(id: UUID(), name: "TEMPO", position: position, color: 0x999999,
                tempoBPM: section.bpm, tempoBeats: section.beats, tempoUnit: section.unit,
                tempoTimebase: active?.tempoTimebase ?? .global, tempoReferenceBPM: active?.tempoReferenceBPM)
        }
        if !targets.contains(where: { abs($0.position - region.startTime) < 0.000001 }) { targets.append(boundary(region.startTime)) }
        let bpms = targets.compactMap(\.tempoBPM)
        let delta = min(300 - (bpms.max() ?? 120), max(60 - (bpms.min() ?? 120), requestedDelta))
        guard abs(delta) > 0.0000001 else { return }
        for i in targets.indices {
            targets[i].tempoBPM! += delta
            targets[i].tempoBeats = targets[i].tempoBeats ?? before.meterBeats
            targets[i].tempoUnit = targets[i].tempoUnit ?? before.meterUnit
        }
        if !(before.markers ?? []).contains(where: { $0.isTempo && abs($0.position - region.endTime) < 0.000001 }) { targets.append(boundary(region.endTime)) }
        targets = targets.map { before.markerWithRegionOwnership($0) }
        var updated = before
        if updated.markers == nil { updated.markers = [] }
        for marker in targets {
            if let i = updated.markers!.firstIndex(where: { $0.id == marker.id }) { updated.markers![i] = marker }
            else { updated.markers!.append(marker) }
        }
        if let initial = updated.initialTempoMarkerIfNeeded { updated.markers!.append(initial); targets.append(initial) }
        do {
            try executor.retimeTempoMarkers(targets)
            let map = TempoEditMap(before: before, after: updated)
            map.apply(to: &updated)
            snapshot.project.songs[index] = updated
            let playback = try executor.playbackSnapshot()
            snapshot.transport = playback.transport; snapshot.nextSongId = playback.nextSongId
            if let restoredCursorPosition { self.restoredCursorPosition = map.position(restoredCursorPosition) }
            rememberCursor(); markChanged(refreshAudio: before.tempoMarkersAffectAudio || updated.tempoMarkersAffectAudio)
            message = ""
        } catch { message = error.localizedDescription }
    }
    @discardableResult public func configureProjectTime(bpm: Double, beats: Int, unit: Int, settings: ProjectTimeSettings) -> Bool {
        guard canExecute(), !finishing, let index = snapshot.project.songs.firstIndex(where: { $0.id == current?.id }) else { return false }
        guard bpm.isFinite, TimelineTempo.bpmRange.contains(bpm), (1...32).contains(beats), TimelineTempo.beatUnits.contains(unit) else { return false }
        do {
            try settings.validate()
            let old = snapshot.project.songs[index]
            guard old.bpm != bpm || old.meterBeats != beats || old.meterUnit != unit || old.projectTime != settings else { return true }
            tick()
            try executor.setProjectTiming(bpm: bpm, beats: beats, unit: unit, settings: settings)
            snapshot.project.songs[index].configureTiming(bpm: bpm, beats: beats, unit: unit, settings: settings)
            let update = try executor.playbackSnapshot()
            snapshot.transport = update.transport; snapshot.nextSongId = update.nextSongId
            let scaledTimeline = settings.timebase == .relative && old.bpm != bpm
            let changedAudio = scaledTimeline || (old.bpm != bpm && snapshot.project.songs[index].tempoMarkersAffectAudio) || (old.projectTime.timebase != settings.timebase && (old.tempoMarkersAffectAudio || snapshot.project.songs[index].tempoMarkersAffectAudio))
            if scaledTimeline, let restoredCursorPosition { self.restoredCursorPosition = restoredCursorPosition * old.bpm / bpm }
            rememberCursor(); resetTapTempo(); markChanged(refreshAudio: changedAudio); message = ""
            return true
        } catch { message = error.localizedDescription; return false }
    }
    public func setTempo(_ bpm: Double) {
        guard bpm.isFinite else { return }
        let value = min(300, max(60, bpm))
        if let region = tempoControlRegion {
            adjustRegionTempo(value - tempoControlBPM, region: region)
        } else if var marker = current?.activeTempoMarker(at: tempoControlPosition), let previous = marker.tempoBPM {
            guard previous != value else { return }
            marker.tempoBPM = value; setMarker(marker)
        } else { updateTiming(.tempo, value: value) }
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
                if song.projectTime.timebase == .relative, let restoredCursorPosition { self.restoredCursorPosition = restoredCursorPosition * old / value }
                rememberCursor()
            case .beatsPerBar: snapshot.project.songs[index].beatsPerBar = Int(value)
            case .beatUnit: snapshot.project.songs[index].beatUnit = Int(value)
            default: return
            }
            markChanged(refreshAudio: command == .tempo && (song.projectTime.timebase == .relative || song.tempoMarkersAffectAudio))
        } catch { message = error.localizedDescription }
    }
    public func updateActiveLoopArea() {
        guard snapshot.transport.loop.enabled, snapshot.transport.multiLoop == nil,
              let range = selectedLoopArea() else { return }
        do {
            try executor.execute(.loopStart, target: nil, value: range.lowerBound)
            try executor.execute(.loopEnd, target: nil, value: range.upperBound)
            snapshot.transport.loop.start = range.lowerBound
            snapshot.transport.loop.end = range.upperBound
        } catch { message = error.localizedDescription }
    }
    public var selectedLoopArea: () -> ClosedRange<Double>? = { nil }
    public func send(_ command: ShowCommand, target: UUID? = nil, value: Double = 0) {
        if [.phase, .masterMono, .volume, .pan, .mute, .solo, .clipMute].contains(command) {
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
            let previous = (command == .queueRegion || command == .escape) ? try executor.playbackSnapshot().transport : snapshot.transport
            if command == .play, let block = selectedSetlistBlock {
                // Resolve at Play time so edits/reordering keep the audible target
                // consistent with the visible playlist, not chronological grid order.
                let entries = setlistEntries
                guard let index = entries.firstIndex(where: { $0.id == block }),
                      let region = entries.dropFirst(index + 1).compactMap({ entry -> Part? in
                          if case .region(let part, _) = entry { return part }; return nil
                      }).first else { return }
                try executor.execute(.selectRegion, target: region.id, value: 0)
                selectedSetlistBlock = nil
            } else if [.editSeek, .seek, .select, .selectRegion, .queueRegion, .queueSection, .next, .previous].contains(command) {
                selectedSetlistBlock = nil
            }
            if command == .toggleLoop, !previous.loop.enabled, let range = selectedLoopArea() {
                try executor.execute(.loopStart, target: nil, value: range.lowerBound)
                try executor.execute(.loopEnd, target: nil, value: range.upperBound)
            }
            try executor.execute(command, target: target, value: value)
            let update = try executor.playbackSnapshot()
            let cancelledRegionQueue = command == .queueRegion && previous.playing &&
                previous.queuedRegionId != nil && update.transport.queuedRegionId == nil
            let cancelledSection = command == .escape && previous.queuedSectionMarkerId != nil
            let disabledAuto = ((command == .escape && !cancelledSection) || cancelledRegionQueue) && snapshot.project.regionSetlist?.autoAdvance == true
            if disabledAuto { snapshot.project.regionSetlist?.autoAdvance = false; setlistRevision &+= 1 }
            if command == .subSeek { revealSubCursor() }
            lastTime = ProcessInfo.processInfo.systemUptime
            snapshot.transport = update.transport; snapshot.nextSongId = update.nextSongId
            if command == .toggleMultiLoopBypass {
                globalDefaults?.set(snapshot.transport.multiLoopsBypassed == true, forKey: Self.multiLoopBypassDefaultsKey)
            }
            applyLoopMixer()
            if disabledAuto { markChanged(refreshAudio: false, preservingMediaStorage: true) }
            focusPreparedRegion(previous: previous)
            if command == .editSeek || (command == .queueSection && !snapshot.transport.playing) {
                navigationFocusPosition = nil
                focusTimelineRegion(at: snapshot.transport.editPosition ?? snapshot.transport.position)
            } else if command == .seek || (command == .play && !previous.playing) {
                focusTimelineRegion(at: snapshot.transport.position, preferredRegion: snapshot.transport.regionId, forceReveal: true)
            }
            rememberCursor()
            if isPlaying { startClock() } else { timer?.invalidate(); timer = nil; onStop() }
            audioUpdate(snapshot, audioProjectRevision)
        } catch { message = error.localizedDescription }
    }
    /// UI controls act on the selection only when their own track is selected.
    /// MIDI/action commands keep their explicit target semantics through send().
    public func mixerControlTargets(_ target: UUID) -> [Track] {
        let tracks = current?.tracks ?? []
        let ids: Set<UUID> = mixerTrackSelection.contains(target) ? mixerTrackSelection : [target]
        return tracks.filter { ids.contains($0.id) }
    }
    private struct MixerGesture {
        let project: UUID
        let target: UUID
        let command: ShowCommand
        let tracks: [Track]
        let original: Double
        var equalized = false
    }
    private var mixerGesture: MixerGesture?
    public private(set) var mixerPreviewValues: [UUID: Double] = [:]
    public private(set) var mixerPreviewIsPan = false
    public func sendMixerControl(_ command: ShowCommand, target: UUID?, value: Double = 0, preview: Bool = false) {
        guard let target else { mixerPreviewValues = [:]; mixerGesture = nil; if preview { previewTrackVolume(nil, gain: value) } else { send(command, value: value) }; return }
        guard canExecute(), !finishing, let source = current?.tracks.first(where: { $0.id == target }) else { return }
        if command == .volume || command == .pan {
            if mixerGesture?.project != snapshot.project.id || mixerGesture?.target != target || mixerGesture?.command != command {
                mixerPreviewValues = [:]
                mixerGesture = MixerGesture(project: snapshot.project.id, target: target, command: command,
                    tracks: mixerControlTargets(target), original: command == .volume ? source.volume : source.pan)
            }
            guard var gesture = mixerGesture else { return }
            if command == .volume && value <= 0 { gesture.equalized = true }
            mixerGesture = gesture
            let all = current?.tracks ?? []
            var values: [UUID: Double] = [:]
            // The touched side leads a linked pair, even when both are selected.
            let ordered = gesture.tracks.sorted { $0.id == target && $1.id != target }
            for track in ordered where values[track.id] == nil {
                let next: Double
                if command == .volume {
                    next = min(pow(10, 12.0 / 20), max(0, gesture.equalized || gesture.original <= 0 ? value : track.volume * value / gesture.original))
                } else { next = min(1, max(-1, track.pan + value - gesture.original)) }
                values[track.id] = next
                if let partner = track.stereoLink?.partner,
                   all.contains(where: { $0.id == partner && $0.stereoLink?.partner == track.id }) {
                    values[partner] = command == .pan ? -next : next
                }
            }
            let previous = Dictionary(uniqueKeysWithValues: all.map { track in
                (track.id, mixerPreviewValues[track.id] ?? (command == .volume ? track.volume : track.pan))
            })
            var applied: [UUID] = []
            do {
                for (id, next) in values { try executor.execute(command, target: id, value: next); applied.append(id) }
                for (id, next) in values {
                    if command == .volume { audioVolume(id, next) } else { audioPan(id, next) }
                }
                mixerPreviewValues = values; mixerPreviewIsPan = command == .pan
                if !preview {
                    var project = snapshot.project
                    for song in project.songs.indices {
                        for index in project.songs[song].tracks.indices {
                            guard let next = values[project.songs[song].tracks[index].id] else { continue }
                            if command == .volume { project.songs[song].tracks[index].volume = next }
                            else { project.songs[song].tracks[index].pan = next }
                        }
                    }
                    snapshot.project = project; mixerGesture = nil
                    markChanged(refreshAudio: false, preservingMediaStorage: true)
                }
            } catch {
                for id in applied.reversed() { if let old = previous[id] { try? executor.execute(command, target: id, value: old) } }
                message = error.localizedDescription; mixerGesture = nil
            }
            return
        }
        guard command == .mute || command == .solo || command == .phase else { send(command, target: target, value: value); return }
        mixerGesture = nil
        func state(_ track: Track) -> Bool {
            command == .mute ? track.mute : (command == .solo ? track.solo : track.phaseInverted == true)
        }
        let desired = !state(source)
        let targets = mixerControlTargets(target).filter { state($0) != desired }
        var applied: [Track] = []
        do {
            for track in targets { try executor.execute(command, target: track.id, value: 0); applied.append(track) }
            var project = snapshot.project
            let ids = Set(targets.map(\.id))
            for song in project.songs.indices {
                for index in project.songs[song].tracks.indices where ids.contains(project.songs[song].tracks[index].id) {
                    let id = project.songs[song].tracks[index].id
                    if command == .mute { project.songs[song].tracks[index].mute = desired; audioMute(id, desired) }
                    else if command == .solo { project.songs[song].tracks[index].solo = desired; audioSolo(id, desired) }
                    else { project.songs[song].tracks[index].phaseInverted = desired; audioPhase(id, desired) }
                    if var base = loopMixerBase[id] {
                        if command == .mute { base.mute.toggle() }
                        if command == .solo { base.solo.toggle() }
                        loopMixerBase[id] = base
                    }
                }
            }
            snapshot.project = project; markChanged(refreshAudio: false, preservingMediaStorage: true)
        } catch {
            for track in applied.reversed() { try? executor.execute(command, target: track.id, value: 0) }
            message = error.localizedDescription
        }
    }
    // Scalar mixer edits update the existing native buses and voices in place.
    private func sendMixer(_ command: ShowCommand, target: UUID?, value: Double) {
        guard canExecute(), !finishing else { return }
        guard command != .phase || target != nil else { return }
        do {
            try executor.execute(command, target: target, value: value)
            var project = loopMixerProject ?? snapshot.project
            // Transfer ownership of the pending mixer frame before mutation.
            // Otherwise each automatic fader copies the songs/tracks arrays
            // again while the previous pending frame still retains their storage.
            if applyingLoopMixer { loopMixerProject = nil }
            if target == nil {
                if command == .volume {
                    let gain = min(pow(10, 12.0 / 20), max(0, value))
                    project.masterVolume = gain; audioVolume(nil, gain)
                }
                if command == .masterMono {
                    let mono = !(project.masterMono ?? false)
                    project.masterMono = mono; audioMasterMono(mono)
                }
                if command == .solo {
                    let solo = !(project.masterSolo ?? false)
                    project.masterSolo = solo; audioMasterSolo(solo)
                }
                if command == .mute {
                    let muted = !(project.masterMute ?? false)
                    project.masterMute = muted; audioMute(nil, muted)
                }
            } else if let target {
                for song in project.songs.indices {
                    for track in project.songs[song].tracks.indices {
                        if command == .clipMute {
                            if let clip = project.songs[song].tracks[track].clips.firstIndex(where: { $0.id == target }) {
                                let muted = !(project.songs[song].tracks[track].clips[clip].muted ?? false)
                                project.songs[song].tracks[track].clips[clip].muted = muted
                                audioClipMute(target, muted)
                            }
                        } else if project.songs[song].tracks[track].id == target {
                            switch command {
                            case .volume:
                                let gain = min(pow(10, 12.0 / 20), max(0, value))
                                project.songs[song].tracks[track].volume = gain; audioVolume(target, gain)
                            case .phase:
                                let inverted = project.songs[song].tracks[track].phaseInverted != true
                                project.songs[song].tracks[track].phaseInverted = inverted; audioPhase(target, inverted)
                            case .pan:
                                let pan = min(1, max(-1, value))
                                project.songs[song].tracks[track].pan = pan; audioPan(target, pan)
                            case .mute:
                                project.songs[song].tracks[track].mute.toggle()
                                audioMute(target, project.songs[song].tracks[track].mute)
                            case .solo:
                                project.songs[song].tracks[track].solo.toggle()
                                audioSolo(target, project.songs[song].tracks[track].solo)
                            default: break
                            }
                        }
                    }
                }
            }
            synchronizeLinkedControl(command, target: target, value: value, project: &project)
            if applyingLoopMixer { loopMixerProject = project }
            else { snapshot.project = project }
            let id = target ?? MultiLoopTrack.masterID
            if !applyingLoopMixer, var base = loopMixerBase[id] {
                if command == .volume { base.volume = value }
                if command == .mute { base.mute.toggle() }
                if command == .solo { base.solo.toggle() }
                loopMixerBase[id] = base
            }
            if applyingLoopMixer {
                loopMixerChanged = true
                mixerPlaybackRevision &+= 1
                // M/S changes the grid's muted appearance. Gain-only movement
                // refreshes mixer controls without invalidating waveform tiles.
                if command == .mute || command == .solo { projectRevision &+= 1 }
            } else { markChanged(refreshAudio: false, preservingMediaStorage: true) }
        } catch { message = error.localizedDescription }
    }
    /// Update the engine while dragging without decoding all waveforms every pixel.
    public func previewTrackVolume(_ track: UUID?, gain: Double) {
        guard canExecute(), !finishing else { return }
        do { try executor.execute(.volume, target: track, value: gain); audioVolume(track, gain); synchronizeLinkedControl(.volume, target: track, value: gain) }
        catch { message = error.localizedDescription }
    }
    public func previewTrackPan(_ track: UUID, pan: Double) {
        guard canExecute(), !finishing else { return }
        let value = min(1, max(-1, pan))
        do { try executor.execute(.pan, target: track, value: value); audioPan(track, value); synchronizeLinkedControl(.pan, target: track, value: value) }
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
            for track in snapshot.project.songs[song].tracks.indices {
                guard let index = snapshot.project.songs[song].tracks[track].clips.firstIndex(where: { $0.id == clip }) else { continue }
                guard snapshot.project.songs[song].tracks[track].kind == .standard || snapshot.project.songs[song].tracks[track].clips[index].isProjectionMedia else { return }
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
        guard NativeFXSettings.order.dropFirst().contains(effect) || effect == NativeFXSettings.stemSeparator else { return }
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
        value.removeInstance(effect)
        previewClipFX(clip, settings: value); commitFX(); onProjectEdited()
    }
    public func updateClipFX(_ clip: UUID, effect: String, settings: NativeFXSettings) {
        guard NativeFXSettings.order.dropFirst().contains(effect) || effect == NativeFXSettings.stemSeparator else { return }
        let current = clipFXSettings(clip)
        var value = current.merging(effect: effect, from: settings)
        if value.isEnabled(effect), !value.inserted.contains(effect) { value.inserted.append(effect) }
        previewClipFX(clip, settings: value)
    }
    public func toggleClipFXAllBypass(_ clip: UUID) {
        guard canExecute(), !finishing else { return }
        for song in snapshot.project.songs.indices {
            for track in snapshot.project.songs[song].tracks.indices {
                guard let index = snapshot.project.songs[song].tracks[track].clips.firstIndex(where: { $0.id == clip }) else { continue }
                guard snapshot.project.songs[song].tracks[track].kind == .standard || snapshot.project.songs[song].tracks[track].clips[index].isProjectionMedia else { return }
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
    public func setMIDIChannel(_ track: UUID, channel: Int) {
        guard canExecute(), !finishing else { return }
        guard let location = trackLocation(track), snapshot.project.songs[location.song].tracks[location.track].midiChannel != (channel == 0 ? nil : channel) else { return }
        do {
            try executor.setMIDIChannel(track, channel: channel)
            snapshot.project.songs[location.song].tracks[location.track].midiChannel = channel == 0 ? nil : channel
            audioMIDIChannel(track, channel)
            markChanged(refreshAudio: false)
        }
        catch { message = error.localizedDescription }
    }
    public func setInputMonitoring(_ track: UUID, enabled: Bool) {
        guard canExecute(), !finishing, let location = trackLocation(track) else { return }
        do {
            try executor.setInputMonitoring(track, enabled: enabled)
            snapshot.project.songs[location.song].tracks[location.track].inputMonitoring = enabled
            markChanged()
        } catch { message = error.localizedDescription }
    }
    public func setRecordingChannels(_ track: UUID, channel: Int) {
        guard canExecute(), !finishing, TrackRecordingMode(rawValue: channel) != nil else { return }
        guard let location = trackLocation(track), snapshot.project.songs[location.song].tracks[location.track].recordingChannels != channel else { return }
        do {
            try executor.setRecordingChannels(track, channel: channel)
            snapshot.project.songs[location.song].tracks[location.track].recordingChannels = channel
            if channel == TrackRecordingMode.midi.rawValue, snapshot.project.songs[location.song].tracks[location.track].midiInput == nil {
                try executor.setMIDIInput(track, slot: 1)
                snapshot.project.songs[location.song].tracks[location.track].midiInput = 1
                audioMIDIInput(track, 1)
            }
            markChanged(refreshAudio: false)
        }
        catch { message = error.localizedDescription }
    }
    public func fxSettings(_ track: UUID?) -> NativeFXSettings {
        track.flatMap { id in snapshot.project.songs.flatMap(\.tracks).first(where: { $0.id == id })?.fx } ?? (track == nil ? snapshot.project.masterFX : nil) ?? NativeFXSettings()
    }
    @discardableResult public func insertFX(_ track: UUID?, effect: String) -> String? {
        guard NativeFXSettings.order.contains(effect) || (track != nil && effect == NativeFXSettings.stemSeparator) else { return nil }
        var value = fxSettings(track)
        let key = value.appendNative(effect)
        previewFX(track, settings: value); commitFX()
        return key
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
        value.removeInstance(effect)
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
            if let link = previous.stereoLink {
                let first = min(1023, max(1, input.firstChannel - (link.left ? 0 : 1)))
                snapshot.project.songs[location.song].tracks[location.track].inputPatch = OutputPatch(firstChannel: first + (link.left ? 0 : 1), channelCount: 1)
                if let other = snapshot.project.songs[location.song].tracks.firstIndex(where: { $0.id == link.partner }) {
                    snapshot.project.songs[location.song].tracks[other].inputPatch = OutputPatch(firstChannel: first + (link.left ? 1 : 0), channelCount: 1)
                }
            } else { snapshot.project.songs[location.song].tracks[location.track].inputPatch = input }
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
            for item in snapshot.project.songs[location.song].tracks[location.track].clips.indices where !snapshot.project.songs[location.song].tracks[location.track].clips[item].isProjectionMedia {
                snapshot.project.songs[location.song].tracks[location.track].clips[item].name = "TIMECODE"
            }
            markChanged(refreshAudio: false)
        }
        catch { message = error.localizedDescription }
    }
    public func insertSeparatedStems(_ tracks: [Track], song: UUID, sourceTrack: UUID, original: AudioClip, project: UUID) throws {
        guard canExecute(), !finishing, snapshot.project.id == project else {
            throw ProjectError.invalid("The destination project is no longer available.")
        }
        var updated = snapshot.project
        try updated.insertSeparatedStems(tracks, song: song, sourceTrack: sourceTrack, original: original)
        try executor.applyProjectEdit(updated)
        snapshot = try executor.snapshot()
        markChanged(); onProjectEdited()
    }
    public func insertAudioTracks(_ tracks: [Track], song: UUID, project: UUID) throws {
        guard canExecute(), !finishing, snapshot.project.id == project,
              let index = snapshot.project.songs.firstIndex(where: { $0.id == song }) else {
            throw ProjectError.invalid("The destination project is no longer available.")
        }
        var tracks = tracks
        let arrangement = snapshot.project.songs[index]
        for row in tracks.indices { for item in tracks[row].clips.indices {
            let clip = tracks[row].clips[item]
            tracks[row].clips[item].regionOwnerID = arrangement.regionOwner(at: clip.startTime)
        } }
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
            var clip = clip
            // MIDI takes already froze their attachment, including nil, at capture start.
            if clip.midi == nil { clip.regionOwnerID = snapshot.project.songs[songIndex].regionOwner(at: clip.startTime) }
            try executor.addRecordedClip(clip, track: track)
            snapshot.project.songs[songIndex].tracks[trackIndex].clips.append(clip)
            snapshot.project.songs[songIndex].duration = max(snapshot.project.songs[songIndex].duration, clip.startTime + clip.duration)
            markChanged()
        }
        catch { message = "Recording saved, but could not insert item: " + error.localizedDescription }
    }
    @discardableResult public func addMIDIItem(track: UUID, start: Double? = nil, duration: Double? = nil) -> UUID? {
        guard canExecute(), !finishing, let current, let row = current.tracks.first(where: { $0.id == track }), row.kind == .standard else { return nil }
        let position = max(0, start ?? snapshot.transport.editPosition ?? snapshot.transport.position)
        let bpm = current.activeTempoMarker(at: position)?.tempoBPM ?? current.bpm
        let length = duration ?? (60 / bpm * Double(current.meterBeats) * 4 / Double(current.meterUnit))
        guard position.isFinite, length.isFinite, length > 0 else { return nil }
        var clip = AudioClip(id: UUID(), name: "MIDI", startTime: position, duration: length, regionOwnerID: current.regionOwner(at: position))
        let rate = current.tempoAudioSegments(clip).first?.audioRate ?? 1
        clip.midi = MIDIItem(sourceBPM: bpm / rate)
        editProject { project in
            guard let song = project.songs.firstIndex(where: { $0.id == current.id }),
                  let index = project.songs[song].tracks.firstIndex(where: { $0.id == track }) else { return }
            project.songs[song].tracks[index].clips.append(clip)
            project.songs[song].duration = max(project.songs[song].duration, position + length)
        }
        return self.current?.tracks.contains(where: { $0.clips.contains(where: { $0.id == clip.id }) }) == true ? clip.id : nil
    }
    public func setMIDIItem(_ id: UUID, midi: MIDIItem) {
        do { try midi.validate() } catch { message = error.localizedDescription; return }
        editProject { project in
            for song in project.songs.indices { for track in project.songs[song].tracks.indices {
                if let clip = project.songs[song].tracks[track].clips.firstIndex(where: { $0.id == id && $0.midi != nil }) {
                    let original = project.songs[song].tracks[track].clips[clip]
                    let previous = Dictionary(uniqueKeysWithValues: (original.midi?.notes ?? []).map { ($0.id, $0) })
                    let changedEnd = midi.notes.filter { previous[$0.id] != $0 }.map(\.end).max()
                    project.songs[song].tracks[track].clips[clip].midi = midi
                    if let changedEnd {
                        let duration = max(original.duration, (changedEnd * 60 / midi.sourceBPM - original.sourceOffset) / original.audioRate)
                        project.songs[song].tracks[track].clips[clip].duration = duration
                        project.songs[song].duration = max(project.songs[song].duration, original.startTime + duration)
                    }
                    return
                }
            } }
        }
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
    public func editMasterColor(_ color: UInt32) {
        guard canExecute(), !finishing, color <= 0xffffff, snapshot.project.masterColor != color else { return }
        do {
            try executor.editMasterColor(color)
            snapshot.project.masterColor = color
            markChanged(refreshAudio: false); onProjectEdited()
        } catch { message = error.localizedDescription }
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
    /// Called once when a native row-height drag finishes. Preview lives in the grid.
    public func setTrackHeightScale(_ id: UUID, scale: Double, project: UUID, song: UUID) {
        guard canExecute(), !finishing, snapshot.project.id == project, current?.id == song,
              TrackHeightGeometry.isValidScale(scale), let location = trackLocation(id),
              snapshot.project.songs[location.song].id == song else { return }
        let value: Double? = abs(scale - 1) < 0.000001 ? nil : scale
        guard snapshot.project.songs[location.song].tracks[location.track].heightScale != value else { return }
        var next = snapshot.project
        next.songs[location.song].tracks[location.track].heightScale = value
        do {
            tick(); try executor.applyProjectEdit(next)
            snapshot = try executor.snapshot()
            markChanged(refreshAudio: false, preservingMediaStorage: true); onProjectEdited()
        } catch { message = error.localizedDescription }
    }
    /// Color-only batch: keep names and audio untouched and create one undo step.
    public func editTrackColors(_ ids: Set<UUID>, color: UInt32, project: UUID) {
        guard canExecute(), !finishing, snapshot.project.id == project,
              color <= 0xffffff, !ids.isEmpty else { return }
        var updated = snapshot.project
        var changed = false
        defer {
            if changed {
                snapshot.project = updated
                markChanged(refreshAudio: false); onProjectEdited()
            }
        }
        do {
            for song in updated.songs.indices {
                for track in updated.songs[song].tracks.indices {
                    let previous = updated.songs[song].tracks[track]
                    guard ids.contains(previous.id), previous.color != color else { continue }
                    try executor.editTrack(previous.id, name: previous.name, color: color)
                    updated.songs[song].tracks[track].color = color
                    changed = true
                }
            }
        } catch {
            // Reflect every successful backend command even if a later command fails;
            // that partial batch is still reversible with a single Undo.
            message = error.localizedDescription
        }
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
    private func synchronizeLinkedControl(_ command: ShowCommand, target: UUID?, value: Double) {
        var project = snapshot.project
        synchronizeLinkedControl(command, target: target, value: value, project: &project)
        if project != snapshot.project { snapshot.project = project }
    }
    private func synchronizeLinkedControl(_ command: ShowCommand, target: UUID?, value: Double, project: inout Project) {
        guard command == .volume || command == .pan, let target,
              let song = project.songs.firstIndex(where: { $0.tracks.contains(where: { $0.id == target }) }),
              let track = project.songs[song].tracks.firstIndex(where: { $0.id == target }),
              let link = project.songs[song].tracks[track].stereoLink,
              let other = project.songs[song].tracks.firstIndex(where: { $0.id == link.partner && $0.stereoLink?.partner == target }) else { return }
        if command == .volume {
            let gain = min(pow(10, 12.0 / 20), max(0, value))
            project.songs[song].tracks[other].volume = gain
            audioVolume(link.partner, gain)
        } else {
            let pan = -min(1, max(-1, value))
            project.songs[song].tracks[other].pan = pan
            audioPan(link.partner, pan)
        }
    }
    public func linkTracks(_ ids: Set<UUID>, defaultInput: Int, color: UInt32) {
        guard let song = current, song.linkableTracks(ids) != nil else { return }
        editProject { project in
            guard let index = project.songs.firstIndex(where: { $0.id == song.id }) else { return }
            let top = project.songs[index].tracks.first { ids.contains($0.id) }!
            project.songs[index].linkTracks(ids, firstInput: max(1, top.inputPatch?.firstChannel ?? defaultInput), color: color)
        }
    }
    public func unlinkTracks(_ id: UUID) {
        editProject { project in for song in project.songs.indices { project.songs[song].unlinkTracks(id) } }
    }
    public func groupTracks(_ ids: Set<UUID>) {
        guard canExecute(), !finishing, ids.count > 1, current?.tracks.contains(where: { ids.contains($0.id) && $0.stereoLink != nil }) != true else { return }
        do { try executor.groupTracks(Array(ids)); snapshot = try executor.snapshot(); markChanged() }
        catch { message = error.localizedDescription }
    }
    public func canDropTrack(_ track: UUID, on target: UUID, after: Bool = false) -> Bool {
        guard track != target, let song = current,
              song.tracks.contains(where: { $0.id == track && $0.kind == .standard }),
              song.tracks.contains(where: { $0.id == target && $0.kind == .standard }),
              !TrackHierarchy(song.tracks).ancestors(of: target).contains(track) else { return false }
        return after || !song.isGroupMemberDrop(track, on: target) || song.groupAdoption(track, above: target) != nil
    }
    public func trackDropJoinsGroup(_ track: UUID, on target: UUID, after: Bool, outsideGroup: Bool = false) -> Bool {
        guard canDropTrack(track, on: target, after: after), let song = current else { return false }
        if let destination = song.normalTrackDropDestination(track, on: target, after: after, outsideGroup: outsideGroup) {
            return !outsideGroup && destination.parent != nil
        }
        return after && song.isGroupMemberDrop(track, on: target)
    }
    public func dropTrack(_ track: UUID, on target: UUID, before: UUID?, outsideGroup: Bool = false) {
        let after = before != target
        guard canDropTrack(track, on: target, after: after), let song = current else { return }
        if song.normalTrackDropDestination(track, on: target, after: after, outsideGroup: outsideGroup) != nil {
            editProject { $0.moveNormalTrack(track, on: target, after: after, outsideGroup: outsideGroup, song: song.id) }
        } else if song.isGroupMemberDrop(track, on: target) {
            if after {
                // Preserve the hit row even at the end of the destination group.
                reorderTrack(track, before: target)
            } else {
                editProject { $0.adoptTracksBelow(target, into: track, song: song.id) }
            }
        } else { reorderTrack(track, before: before) }
    }
    public func reorderTrack(_ track: UUID, before: UUID?) {
        guard canExecute(), !finishing, track != before,
              current?.tracks.contains(where: { $0.id == track && $0.kind == .standard }) == true else { return }
        do { try executor.reorderTrack(track, before: before); snapshot = try executor.snapshot(); markChanged() }
        catch { message = error.localizedDescription }
    }
    public static func sequentialInputPatches(count: Int, channels: Int) -> [OutputPatch] {
        guard count > 0, channels > 0 else { return [] }
        return (0..<count).map { OutputPatch(firstChannel: $0 % channels + 1, channelCount: 1) }
    }
    @discardableResult public func addTracks(name: String, role: TrackRole, count: Int, inputPatches: [OutputPatch] = [], after selected: UUID? = nil) -> [UUID] {
        guard canExecute(), !finishing, let songIndex = snapshot.project.songs.firstIndex(where: { $0.id == current?.id }) else { return [] }
        guard count > 0 else { return [] }
        let kind = TrackKind(rawValue: role.rawValue) ?? .standard
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind != .standard || !trimmed.isEmpty else { message = "Nome da pista"; return [] }
        guard kind == .standard || count == 1 else { message = "Special tracks must be created one at a time."; return [] }
        guard inputPatches.isEmpty || inputPatches.count == count else { message = "Invalid input routing."; return [] }
        if kind != .standard && snapshot.project.songs.contains(where: { $0.tracks.contains { $0.kind == kind } }) {
            message = "A \(kind.title) track already exists."; return []
        }
        var project = snapshot.project
        let existing = project.songs[songIndex].tracks
        let selectedIndex = selected.flatMap { id in existing.firstIndex { $0.id == id } }
        let insertion = kind == .standard ? selectedIndex.map { $0 + 1 } ?? existing.count : existing.count
        let parent: UUID?
        if kind == .standard, let selectedIndex {
            let selected = existing[selectedIndex]
            parent = existing.contains { $0.parentTrackID == selected.id } ? selected.id : selected.parentTrackID
        } else { parent = nil }
        var newTracks: [Track] = []
        for index in 0..<count {
            let trackName = kind == .standard ? trimmed + (count == 1 ? "" : String(format: " %02d", index + 1)) : kind.title
            var track = Track(id: UUID(), name: trackName, role: role, color: kind == .standard ? Track.defaultStandardColor : nil)
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
        let kind = TrackKind(rawValue: role.rawValue) ?? .standard
        if kind != .standard && snapshot.project.songs.contains(where: { $0.tracks.contains { $0.kind == kind } }) {
            message = "A \(kind.title) track already exists."; return nil
        }
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
    public func setClickSound(track id: UUID, file: AudioFile?) {
        guard current?.tracks.contains(where: { $0.id == id && $0.kind == .click }) == true else { return }
        editProject { project in
            for song in project.songs.indices {
                if let track = project.songs[song].tracks.firstIndex(where: { $0.id == id }) {
                    project.songs[song].tracks[track].clickSound = file
                }
            }
        }
    }
    public func insertClickItems(track id: UUID) {
        guard canExecute(), !finishing else { return }
        var project = snapshot.project
        guard project.insertClickItems(track: id) > 0 else { return }
        do {
            try project.validate()
            tick(); try executor.applyProjectEdit(project)
            snapshot = try executor.snapshot(); markChanged(); onProjectEdited(); message = ""
        } catch { message = error.localizedDescription }
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
        guard canExecute(), !finishing, (-12...12).contains(semitones),
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
    public func editRegionColors(_ ids: Set<UUID>, color: UInt32) {
        guard canExecute(), !finishing, color <= 0xffffff,
              let song = snapshot.project.songs.firstIndex(where: { $0.id == snapshot.transport.songId }) else { return }
        var changed = false
        defer { if changed { markChanged(refreshAudio: false); onProjectEdited() } }
        do {
            for index in snapshot.project.songs[song].parts.indices {
                let region = snapshot.project.songs[song].parts[index]
                guard ids.contains(region.id), region.color != color else { continue }
                try executor.editRegion(region.id, name: region.name, color: color, uppercaseName: region.usesUppercase)
                snapshot.project.songs[song].parts[index].color = color
                snapshot.project.songs[song].parts[index].uppercaseName = region.usesUppercase
                changed = true
            }
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
            guard let destination = track.flatMap({ id in current?.tracks.first { $0.id == id } }) ?? (track == nil ? source : nil) else { return }
            let mediaTransfer = clip.isProjectionMedia
            guard source.id == destination.id || (source.kind == .standard && destination.kind == .standard) || mediaTransfer else { return }
            guard destination.canPlaceItem(start: start, duration: clip.duration, excluding: source.id == destination.id ? id : nil, media: clip.isProjectionMedia) else { return }
        }
        do { try executor.moveClip(id, start: start, track: track); snapshot = try executor.snapshot(); markChanged() }
        catch { message = error.localizedDescription }
    }
    /// Commit a drop into the first empty mixer row as one undoable project edit.
    public func moveClipToNewStandardTrack(_ id: UUID, start: Double, newTrack: Track) {
        guard canExecute(), !finishing, newTrack.kind == .standard,
              start.isFinite, start >= 0,
              let songIndex = snapshot.project.songs.firstIndex(where: { $0.id == current?.id }),
              let sourceIndex = snapshot.project.songs[songIndex].tracks.firstIndex(where: { $0.clips.contains { $0.id == id } }),
              snapshot.project.songs[songIndex].tracks[sourceIndex].kind == .standard,
              let clipIndex = snapshot.project.songs[songIndex].tracks[sourceIndex].clips.firstIndex(where: { $0.id == id }) else { return }
        var project = snapshot.project
        var clip = project.songs[songIndex].tracks[sourceIndex].clips.remove(at: clipIndex)
        clip.startTime = start
        var destination = newTrack
        if destination.color == nil { destination.color = Track.defaultStandardColor }
        destination.clips = [clip]
        project.songs[songIndex].tracks.append(destination)
        project.songs[songIndex].duration = max(project.songs[songIndex].duration, start + clip.duration)
        do {
            try project.validate()
            tick(); try executor.applyProjectEdit(project)
            snapshot = try executor.snapshot(); markChanged(); onProjectEdited()
            message = ""
        } catch { message = error.localizedDescription }
    }
    public func deleteManualMarker(_ id: UUID) {
        guard canExecute(), !finishing, let song = snapshot.project.songs.firstIndex(where: { $0.id == snapshot.transport.songId }),
              let marker = snapshot.project.songs[song].markers?.first(where: { $0.id == id }),
              marker.unifiedRegionID == nil, marker.sourceRegionID == nil else { return }
        do {
            let affectedAudio = marker.isTempo && snapshot.project.songs[song].tempoMarkersAffectAudio
            try executor.deleteManualMarker(id)
            snapshot.project.songs[song].markers?.removeAll { $0.id == id }
            for part in snapshot.project.songs[song].parts.indices {
                snapshot.project.songs[song].parts[part].multiLoops?.removeAll { $0.marker1 == id || $0.marker2 == id }
            }
            snapshot.transport = try executor.playbackSnapshot().transport
            markChanged(refreshAudio: affectedAudio)
        } catch { message = error.localizedDescription }
    }
    @discardableResult public func applyDetectedTempo(_ markers: [TimelineMarker], project: UUID, song: UUID, region: UUID? = nil) -> Bool {
        guard canExecute(), !finishing, project == snapshot.project.id,
              let index = snapshot.project.songs.firstIndex(where: { $0.id == song }), snapshot.transport.songId == song,
              !markers.isEmpty, markers.allSatisfy({ $0.isTempo }) else { return false }
        do {
            var updated = snapshot.project.songs[index]
            let before = updated.markers ?? []
            updated.insertDetectedTempo(markers, replacing: region.flatMap { id in updated.parts.first { $0.id == id } })
            let retained = Set(updated.markers?.map(\.id) ?? [])
            let removed = before.filter { !retained.contains($0.id) }.map(\.id)
            let additions = (updated.markers ?? []).filter { !before.contains($0) }
            try executor.setTempoMarkers(additions, removing: removed)
            snapshot.project.songs[index] = updated
            markChanged(refreshAudio: snapshot.project.songs[index].tempoMarkersAffectAudio)
            return true
        } catch { message = error.localizedDescription; return false }
    }
    public func setTotalLoop(_ enabled: Bool, region: UUID) {
        guard current?.parts.contains(where: { $0.id == region }) == true else { return }
        editProject { project in
            for s in project.songs.indices {
                if let p = project.songs[s].parts.firstIndex(where: { $0.id == region }) {
                    project.songs[s].parts[p].totalLoop = enabled
                }
            }
        }
    }
    @discardableResult public func setMultiLoops(_ loops: [MultiLoop], region: UUID) -> Bool {
        guard let song = current, let part = song.parts.first(where: { $0.id == region }),
              !song.parts.contains(where: { $0.parentRegionID == region }) else { return false }
        do {
            let markers = song.multiLoopMarkers(in: part)
            for loop in loops {
                try loop.validate()
                guard let a = markers.first(where: { $0.id == loop.marker1 }),
                      let b = markers.first(where: { $0.id == loop.marker2 }), a.position < b.position else {
                    throw ProjectError.invalid("Choose two different markers in chronological order")
                }
            }
            if loops.contains(where: { song.multiLoopConflicts($0, replacingRegion: region, replacement: loops) }) {
                modalNotice = "A multiloop cannot exist inside another multiloop."; return false
            }
            editProject { project in
                for s in project.songs.indices {
                    if let p = project.songs[s].parts.firstIndex(where: { $0.id == region }) { project.songs[s].parts[p].multiLoops = loops }
                }
            }
            return current?.parts.first(where: { $0.id == region })?.multiLoops == loops
        } catch { message = error.localizedDescription; return false }
    }
    @discardableResult public func canCreateMarker(at position: Double, tempo: Bool = false) -> Bool {
        guard current?.markers?.contains(where: { $0.isTempo == tempo && abs($0.position - position) < 0.000001 }) != true else {
            modalNotice = "A marker already exists at this position."; return false
        }
        return true
    }
    public func setMarker(_ marker: TimelineMarker) {
        guard canExecute(), !finishing, let song = snapshot.project.songs.firstIndex(where: { $0.id == snapshot.transport.songId }) else { return }
        var value = marker
        let previous = snapshot.project.songs[song].markers?.first { $0.id == marker.id }
        value.applySectionPrefix()
        if previous?.isLoopSection == true, !value.isLoopSection,
           snapshot.project.songs[song].parts.contains(where: { ($0.multiLoops ?? []).contains { $0.marker1 == marker.id || $0.marker2 == marker.id } }) {
            modalNotice = "Remova este marcador dos Multiloops antes de mudar seu tipo."
            return
        }
        if value.isSection && !canCreateSectionMarker(at: marker.position, includingEnd: previous != nil) { return }
        if previous == nil, !canCreateMarker(at: marker.position, tempo: marker.isTempo) { return }
        if let previous { value.unifiedRegionID = previous.unifiedRegionID; value.sourceRegionID = previous.sourceRegionID; value.tempoReferenceBPM = value.isTempo ? previous.tempoReferenceBPM : nil }
        let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.name = value.isSection ? String(name.uppercased().prefix(TimelineMarker.maximumSectionNameLength)) : value.unifiedRegionID == nil ? String(name.prefix(TimelineMarker.maximumNameLength)) : name
        guard !value.name.isEmpty else { return }
        value = snapshot.project.songs[song].markerWithRegionOwnership(value)
        do {
            let beforeTempoEdit = snapshot.project.songs[song]
            let affectedAudio = snapshot.project.songs[song].tempoMarkersAffectAudio
            try executor.setMarker(value)
            if let index = snapshot.project.songs[song].markers?.firstIndex(where: { $0.id == value.id }) {
                snapshot.project.songs[song].markers![index] = value
            } else {
                if snapshot.project.songs[song].markers == nil { snapshot.project.songs[song].markers = [] }
                snapshot.project.songs[song].markers!.append(value)
            }
            snapshot.project.songs[song].duration = max(snapshot.project.songs[song].duration, value.position)
            if value.isTempo && (previous?.tempoBPM != value.tempoBPM || previous?.tempoTimebase != value.tempoTimebase) {
                let map = TempoEditMap(before: beforeTempoEdit, after: snapshot.project.songs[song])
                map.apply(to: &snapshot.project.songs[song]); map.apply(to: &snapshot.transport)
            }
            if value.isTempo, let initial = snapshot.project.songs[song].initialTempoMarkerIfNeeded {
                try executor.setTempoMarkers([initial])
                snapshot.project.songs[song].markers!.insert(initial, at: 0)
            }
            markChanged(refreshAudio: (value.isTempo || previous?.isTempo == true) && (affectedAudio || snapshot.project.songs[song].tempoMarkersAffectAudio))
        } catch { message = error.localizedDescription }
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
    public func regionFromTimeSelection(song: UUID, start: Double, end: Double) {
        guard canExecute(), !finishing, song == current?.id,
              start.isFinite, end.isFinite, start >= 0, end > start,
              let index = snapshot.project.songs.firstIndex(where: { $0.id == song }) else { return }
        guard current?.parts.contains(where: { abs($0.startTime - start) < 0.000001 }) != true else {
            modalNotice = "A region already starts at this position."; return
        }
        let region = Part(id: UUID(), name: NSLocalizedString("New region", comment: "Region created from a time selection"),
                          startTime: start, endTime: end, color: 0x55cc88)
        editProject { project in
            project.songs[index].parts.append(region)
            project.songs[index].parts.sort { $0.startTime < $1.startTime }
        }
        if current?.parts.contains(where: { $0.id == region.id }) == true {
            focusedRegion = region.id; regionFocusRequest = UUID(); message = ""
        }
    }
    public func regionsFromSelection(_ ids: Set<UUID>) {
        guard canExecute(), !finishing, let track = current?.tracks.first(where: { $0.kind != .timecode && $0.clips.contains { ids.contains($0.id) } }) else { return }
        let lanes = TrackLanes(track: track).lanes
        let topLane = track.clips.filter { ids.contains($0.id) }.compactMap { lanes[$0.id] }.min() ?? 0
        let clips = track.clips.filter { ids.contains($0.id) && lanes[$0.id] == topLane }.sorted { $0.startTime < $1.startTime }
        var starts = current?.parts.map(\.startTime) ?? []
        let available = clips.filter { clip in
            guard !starts.contains(where: { abs($0 - clip.startTime) < 0.000001 }) else { return false }
            starts.append(clip.startTime); return true
        }
        guard !available.isEmpty else { modalNotice = "A region already starts at this position."; return }
        do {
            try executor.regionsFromClips(available.map(\.id)); snapshot = try executor.snapshot(); markChanged()
            if available.count != clips.count { modalNotice = "A region already starts at this position." }
        } catch { message = error.localizedDescription }
    }
    public func regionFromClip(_ id: UUID) {
        guard canExecute(), !finishing,
              current?.tracks.contains(where: { $0.kind != .timecode && $0.clips.contains { $0.id == id } }) == true else { return }
        if let clip = current?.tracks.flatMap(\.clips).first(where: { $0.id == id }),
           current?.parts.contains(where: { abs($0.startTime - clip.startTime) < 0.000001 }) == true {
            modalNotice = "A region already starts at this position."; return
        }
        do { try executor.regionFromClip(id); snapshot = try executor.snapshot(); markChanged() }
        catch { message = error.localizedDescription }
    }
    private func rememberCursor() {
        cursorMemory?.remember(project: snapshot.project.id, songID: snapshot.transport.songId,
                               position: snapshot.transport.editPosition ?? snapshot.transport.position)
    }
    private func restoreCursor() throws {
        // The document's saved position wins over a later local navigation or
        // preferences from another installation. Local memory serves unsaved documents.
        guard let saved = snapshot.project.savedCursor ?? cursorMemory?.cursor(for: snapshot.project.id),
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
        project.savedCursor = editingCursor
        try await persistence.save(project)
        if snapshot.project.id == project.id { lastSavedCursor = project.savedCursor; lastSavedAt = project.updatedAt }
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
    private func markChanged(refreshAudio: Bool = true, preservingMediaStorage: Bool = false) {
        recordEdit(preservingMediaStorage: preservingMediaStorage)
        projectRevision &+= 1
        if refreshAudio { audioProjectRevision &+= 1 }
        hasUnsavedChanges = true
        audioUpdate(snapshot, audioProjectRevision)
    }
    /// Prepare playback after the document has selected its media directory.
    public func preparePlayback() { audioUpdate(snapshot, audioProjectRevision) }
    public func replaceProject(_ project: Project) throws {
        lastSavedAt = nil
        regionNavigationTask?.cancel(); regionNavigationTask = nil
        try project.validate()
        timer?.invalidate(); timer = nil
        try executor.load(project); snapshot = try executor.snapshot(); resetLoopMixer(); try restoreGlobalBypass()
        lastSavedCursor = project.savedCursor
        projectRevision &+= 1; hasUnsavedChanges = false
        audioProjectRevision &+= 1
        itemClipboard = nil
        selectedSetlistBlock = nil
        selectedTimelineRegion = nil; timelineFollowPaused = false
        focusedRegion = nil; restoredCursorPosition = nil; navigationFocusPosition = nil; regionFocusRequest = UUID(); message = ""
        try restoreCursor(); resetHistory()
    }
    public func importProject(_ data: Data) throws {
        let project = try ProjectDocumentCodec.decode(data)
        selectedTimelineRegion = nil; timelineFollowPaused = false
        try executor.load(project); snapshot = try executor.snapshot(); resetLoopMixer(); try restoreGlobalBypass(); try restoreCursor(); markChanged()
        lastSavedCursor = project.savedCursor
    }
}

/// Only visible region bands and ordinary markers participate in navigation.
/// Children of a unified region are represented by their ordinary markers.
public struct TimelineNavigationPoints {
    public let regionStarts: [Double]
    public let points: [Double]
    public init(song: Song) {
        let regions = song.parts.filter { $0.parentRegionID == nil }
        regionStarts = Array(Set(regions.map(\.startTime).filter { $0.isFinite && $0 >= 0 })).sorted()
        points = Array(Set((regions.flatMap { [$0.startTime, $0.endTime] } + (song.markers ?? []).filter { !$0.isTempo }.map(\.position))
            .filter { $0.isFinite && $0 >= 0 })).sorted()
    }
    public func target(for action: DAWAction, position: Double) -> Double? {
        switch action {
        case .projectStart: return 0
        case .projectEnd: return points.last ?? 0
        case .nextRegion, .previousRegion, .nextTimelinePoint, .previousTimelinePoint:
            let candidates = action == .nextRegion || action == .previousRegion ? regionStarts : points
            let forward = action == .nextRegion || action == .nextTimelinePoint
            let threshold = position + (forward ? 0.0000001 : -0.0000001)
            var low = 0, high = candidates.count
            while low < high {
                let middle = (low + high) / 2
                if forward ? candidates[middle] <= threshold : candidates[middle] < threshold { low = middle + 1 }
                else { high = middle }
            }
            let index = forward ? low : low - 1
            return candidates.indices.contains(index) ? candidates[index] : nil
        default: return nil
        }
    }
}
