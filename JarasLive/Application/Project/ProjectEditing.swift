import Foundation

public enum GridDeleteTarget: Equatable {
    case items(Set<UUID>), tracks(Set<UUID>), none
    public init(items: Set<UUID>, tracks: Set<UUID>) {
        self = !items.isEmpty ? .items(items) : !tracks.isEmpty ? .tracks(tracks) : .none
    }
}

public extension Project {
    /// Track IDs may appear in more than one song; deletion removes them all.
    func tracksContainItems(_ ids: Set<UUID>) -> Bool {
        songs.contains { song in song.tracks.contains { ids.contains($0.id) && !$0.clips.isEmpty } }
    }
    /// Only connected overlapping roots form a group; touching edges stay separate.
    func overlappingRegions(containing id: UUID) -> [Part] {
        guard let song = songs.first(where: { $0.parts.contains { $0.id == id } }),
              let seed = song.parts.first(where: { $0.id == id && $0.parentRegionID == nil }) else { return [] }
        var members: Set<UUID> = [seed.id]
        var start = seed.startTime, end = seed.endTime
        var changed = true
        while changed {
            changed = false
            for region in song.parts where region.parentRegionID == nil && !members.contains(region.id) {
                if region.startTime < end && region.endTime > start {
                    members.insert(region.id); start = min(start, region.startTime); end = max(end, region.endTime); changed = true
                }
            }
        }
        return song.parts.filter { members.contains($0.id) }.sorted { $0.startTime == $1.startTime ? $0.endTime < $1.endTime : $0.startTime < $1.startTime }
    }
    @discardableResult mutating func unifyRegions(containing id: UUID, name: String) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let roots = overlappingRegions(containing: id)
        guard roots.count > 1, let first = roots.first,
              let songIndex = songs.firstIndex(where: { $0.parts.contains { $0.id == id } }) else { throw ProjectError.invalid("Select overlapping regions") }
        let rootIDs = Set(roots.map(\.id))
        let children = songs[songIndex].parts.filter { $0.parentRegionID.map(rootIDs.contains) == true }
        // Existing unified groups flatten into one drawer, preserving their songs.
        let replacedGroups = Set(children.compactMap(\.parentRegionID))
        let existingGroup = roots.first { $0.id == id && replacedGroups.contains($0.id) }
            ?? roots.first { replacedGroups.contains($0.id) }
        guard existingGroup != nil || !name.isEmpty else { throw ProjectError.invalid("Choose a name") }
        let members = (roots.filter { !replacedGroups.contains($0.id) } + children)
            .sorted { $0.startTime == $1.startTime ? $0.endTime < $1.endTime : $0.startTime < $1.startTime }
        let firstFile = songs[songIndex].tracks.filter { $0.kind == .standard }.flatMap(\.clips)
            .filter { $0.startTime >= first.startTime && $0.startTime < first.endTime }.map(\.startTime).min()
        let start = min(firstFile ?? first.startTime, (members.map(\.endTime).min() ?? first.endTime) - 0.001)
        let end = roots.map(\.endTime).max()!
        var group = existingGroup ?? Part(id: UUID(), name: name, startTime: start, endTime: end, color: first.color)
        group.startTime = start; group.endTime = end
        songs[songIndex].parts.removeAll { replacedGroups.contains($0.id) }
        let memberIDs = Set(members.map(\.id))
        for index in songs[songIndex].parts.indices where memberIDs.contains(songs[songIndex].parts[index].id) {
            songs[songIndex].parts[index].parentRegionID = group.id
            songs[songIndex].parts[index].startTime = max(start, songs[songIndex].parts[index].startTime)
        }
        songs[songIndex].parts.append(group)
        for track in songs[songIndex].tracks.indices {
            for clip in songs[songIndex].tracks[track].clips.indices {
                if songs[songIndex].tracks[track].clips[clip].regionOwnerID.map(replacedGroups.contains) == true {
                    songs[songIndex].tracks[track].clips[clip].regionOwnerID = group.id
                }
            }
        }
        var markers = songs[songIndex].markers ?? []
        for index in markers.indices where markers[index].regionOwnerID.map(replacedGroups.contains) == true {
            markers[index].regionOwnerID = group.id
        }
        let originalMarkers = Dictionary(uniqueKeysWithValues: markers.compactMap { marker -> (UUID, TimelineMarker)? in
            guard let source = marker.sourceRegionID, marker.unifiedRegionID.map(replacedGroups.contains) == true else { return nil }
            return (source, marker)
        })
        markers.removeAll { $0.unifiedRegionID.map(replacedGroups.contains) == true }
        markers += members.map { TimelineMarker(id: UUID(), name: originalMarkers[$0.id]?.name ?? $0.name, position: originalMarkers[$0.id]?.position ?? $0.startTime, color: originalMarkers[$0.id]?.color ?? $0.color ?? 0x54ff93, unifiedRegionID: group.id, sourceRegionID: $0.id) }
        songs[songIndex].markers = markers
        if var state = regionSetlist {
            for index in state.playlists.indices where state.playlists[index].songId == songs[songIndex].id {
                var inserted = false
                state.playlists[index].regionIds = state.playlists[index].regionIds.compactMap { region in
                    guard rootIDs.contains(region) || memberIDs.contains(region) else { return region }
                    if inserted { return nil }; inserted = true; return group.id
                }
            }
            if var blocks = state.blocks {
                for index in blocks.indices where blocks[index].beforeRegionId.map(rootIDs.union(memberIDs).contains) == true { blocks[index].beforeRegionId = group.id }
                state.blocks = blocks
            }
            regionSetlist = state
        }
        try validate()
        return group.id
    }
    @discardableResult mutating func disunifyRegion(_ id: UUID) throws -> [UUID] {
        guard let song = songs.firstIndex(where: { $0.parts.contains { $0.id == id && $0.parentRegionID == nil } }) else { throw ProjectError.invalid("Unknown unified region") }
        let members = songs[song].parts.filter { $0.parentRegionID == id }.sorted { $0.startTime < $1.startTime }
        guard !members.isEmpty else { throw ProjectError.invalid("Unknown unified region") }
        let markers = (songs[song].markers ?? []).filter { $0.unifiedRegionID == id }
        var candidate = self
        for index in candidate.songs[song].parts.indices where candidate.songs[song].parts[index].parentRegionID == id {
            let source = candidate.songs[song].parts[index].id
            candidate.songs[song].parts[index].parentRegionID = nil
            if let marker = markers.first(where: { $0.sourceRegionID == source }) {
                candidate.songs[song].parts[index].startTime = marker.position
                candidate.songs[song].parts[index].name = marker.name
                candidate.songs[song].parts[index].color = marker.color
            }
        }
        candidate.songs[song].parts.removeAll { $0.id == id }
        candidate.songs[song].markers?.removeAll { $0.unifiedRegionID == id }
        let remaining = candidate.songs[song]
        for track in remaining.tracks.indices {
            for clip in remaining.tracks[track].clips.indices where remaining.tracks[track].clips[clip].regionOwnerID == id {
                let item = remaining.tracks[track].clips[clip]
                candidate.songs[song].tracks[track].clips[clip].regionOwnerID = remaining.regionOwner(at: item.startTime, end: item.startTime + item.duration)
            }
        }
        for index in (remaining.markers ?? []).indices where remaining.markers?[index].regionOwnerID == id {
            candidate.songs[song].markers?[index].regionOwnerID = remaining.regionOwner(at: remaining.markers![index].position)
        }
        if var state = candidate.regionSetlist {
            for index in state.playlists.indices {
                state.playlists[index].regionIds = state.playlists[index].regionIds.flatMap { $0 == id ? members.map(\.id) : [$0] }
            }
            if var blocks = state.blocks {
                for index in blocks.indices where blocks[index].beforeRegionId == id { blocks[index].beforeRegionId = members.first?.id }
                state.blocks = blocks
            }
            candidate.regionSetlist = state
        }
        try candidate.validate()
        self = candidate
        return members.map(\.id)
    }
    /// Special tracks keep a stable prefix; normal tracks and their groups retain their order.
    mutating func orderSpecialTracks() {
        let order: [TrackKind] = [.timecode, .click, .chords, .teleprompt, .teleprompt2, .video, .standard]
        for song in songs.indices {
            let tracks = songs[song].tracks
            let ranks = tracks.map { order.firstIndex(of: $0.kind)! }
            guard zip(ranks, ranks.dropFirst()).contains(where: { $0.0 > $0.1 }) else { continue }
            songs[song].tracks = order.flatMap { kind in tracks.filter { $0.kind == kind } }
        }
    }
    /// Removing an item never removes its source file. History keeps this value
    /// and shares the immutable waveform storage through Swift copy-on-write.
    mutating func resizeItem(_ id: UUID, start: Double, end: Double) {
        guard start.isFinite, end.isFinite, start >= 0, end - start >= 0.01 else { return }
        for song in songs.indices {
            for track in songs[song].tracks.indices {
                guard let index = songs[song].tracks[track].clips.firstIndex(where: { $0.id == id }) else { continue }
                guard songs[song].tracks[track].canPlaceItem(start: start, duration: end - start, excluding: id) else { return }
                if songs[song].tracks[track].kind == .timecode {
                    if songs[song].tracks[track].importedTimecodeItems == true {
                        songs[song].tracks[track].clips[index].startTime = start
                        songs[song].tracks[track].clips[index].duration = end - start
                        songs[song].duration = max(songs[song].duration, end)
                        return
                    }
                    guard let region = songs[song].parts.first(where: { Self.timecodeItemID($0.id) == id }) else { return }
                    songs[song].tracks[track].clips[index].timecodeStartOffset = start - region.startTime
                    songs[song].tracks[track].clips[index].timecodeEndOffset = end - region.endTime
                    songs[song].tracks[track].clips[index].startTime = start
                    songs[song].tracks[track].clips[index].duration = end - start
                } else if songs[song].tracks[track].kind.isText && !songs[song].tracks[track].clips[index].isProjectionMedia {
                    songs[song].tracks[track].clips[index].startTime = start
                    songs[song].tracks[track].clips[index].duration = end - start
                } else if songs[song].tracks[track].kind == .standard {
                    songs[song].tracks[track].clips[index] = songs[song].tracks[track].clips[index].resized(start: start, end: end)
                } else { continue }
                songs[song].duration = max(songs[song].duration, end)
            }
        }
    }
    mutating func splitItems(_ ids: Set<UUID>, at position: Double) {
        guard position.isFinite else { return }
        for song in songs.indices {
            for track in songs[song].tracks.indices where songs[song].tracks[track].kind != .timecode {
                let textTrack = songs[song].tracks[track].kind.isText
                songs[song].tracks[track].clips = songs[song].tracks[track].clips.flatMap { clip -> [AudioClip] in
                    guard ids.contains(clip.id), position > clip.startTime + 0.000001, position < clip.startTime + clip.duration - 0.000001 else { return [clip] }
                    var left = clip, right = clip
                    left.duration = position - clip.startTime
                    right.id = UUID(); right.startTime = position; right.duration = clip.duration - left.duration
                    if textTrack { return [left, right] }
                    right.sourceOffset += left.duration * clip.audioRate
                    let fraction = left.duration / clip.duration
                    func pieces(_ peaks: [Double]) -> ([Double], [Double]) {
                        let cut = min(peaks.count, max(0, Int((Double(peaks.count) * fraction).rounded())))
                        return (Array(peaks.prefix(cut)), Array(peaks.dropFirst(cut)))
                    }
                    if clip.loopLength == nil {
                        (left.waveform, right.waveform) = pieces(clip.waveform)
                        left.waveformChannels = clip.waveformChannels?.map { pieces($0).0 }
                        right.waveformChannels = clip.waveformChannels?.map { pieces($0).1 }
                    }
                    return [left, right]
                }
            }
        }
    }
    mutating func deleteItems(_ ids: Set<UUID>) {
        for song in songs.indices {
            for track in songs[song].tracks.indices where songs[song].tracks[track].kind != .timecode {
                songs[song].tracks[track].clips.removeAll { ids.contains($0.id) }
            }
        }
    }
    mutating func moveNormalTrack(_ source: UUID, on target: UUID, after: Bool, outsideGroup: Bool, song songID: UUID) {
        guard let song = songs.firstIndex(where: { $0.id == songID }),
              let destination = songs[song].normalTrackDropDestination(source, on: target, after: after, outsideGroup: outsideGroup),
              var moving = songs[song].tracks.first(where: { $0.id == source }) else { return }
        var remaining = songs[song].tracks.filter { $0.id != source }
        if moving.parentTrackID != destination.parent {
            if let parent = destination.parent { moving.sendToGroup(parent) }
            else { moving.detachFromGroup() }
        }
        let insertion = destination.before.flatMap { before in remaining.firstIndex { $0.id == before } } ?? remaining.count
        remaining.insert(moving, at: insertion)
        songs[song].tracks = remaining
        orderSpecialTracks()
    }
    /// A folder dropped ABOVE a member stays outside the old folder and
    /// adopts that member and the following siblings, preserving their trees.
    mutating func adoptTracksBelow(_ target: UUID, into source: UUID, song songID: UUID) {
        guard let song = songs.firstIndex(where: { $0.id == songID }),
              let adoption = songs[song].groupAdoption(source, above: target) else { return }
        let tracks = songs[song].tracks, hierarchy = TrackHierarchy(tracks)
        guard let parent = tracks.first(where: { $0.id == adoption.parent }) else { return }
        let sourceIDs = hierarchy.descendants(of: source).union([source])
        let adoptedIDs = adoption.roots.reduce(into: Set<UUID>()) { $0.formUnion(hierarchy.descendants(of: $1).union([$1])) }
        let folderIDs = hierarchy.descendants(of: parent.id).union([parent.id])
        var moving = tracks.filter { sourceIDs.contains($0.id) }
        var adopted = tracks.filter { adoptedIDs.contains($0.id) }
        var remaining = tracks.filter { !sourceIDs.contains($0.id) && !adoptedIDs.contains($0.id) }
        guard let root = moving.firstIndex(where: { $0.id == source }),
              let last = remaining.lastIndex(where: { folderIDs.contains($0.id) }) else { return }
        if let outer = parent.parentTrackID { moving[root].sendToGroup(outer) }
        else { moving[root].detachFromGroup() }
        let roots = Set(adoption.roots)
        for index in adopted.indices where roots.contains(adopted[index].id) { adopted[index].sendToGroup(source) }
        // The hit track becomes the first child; retain the order of both trees.
        moving.insert(contentsOf: adopted, at: root + 1)
        remaining.insert(contentsOf: moving, at: last + 1)
        songs[song].tracks = remaining
        orderSpecialTracks()
    }
    /// Remove just this subtree from its immediate folder, placing it after
    /// that folder's remaining children while preserving the internal routes.
    mutating func removeTrackFromGroup(_ id: UUID) {
        for song in songs.indices {
            let tracks = songs[song].tracks
            guard let source = tracks.first(where: { $0.id == id }),
                  let parentID = source.parentTrackID,
                  let parent = tracks.first(where: { $0.id == parentID }) else { continue }
            let hierarchy = TrackHierarchy(tracks)
            let movingIDs = hierarchy.descendants(of: id).union([id])
            let folderIDs = hierarchy.descendants(of: parentID).union([parentID])
            var moving = tracks.filter { movingIDs.contains($0.id) }
            var remaining = tracks.filter { !movingIDs.contains($0.id) }
            guard let root = moving.firstIndex(where: { $0.id == id }),
                  let last = remaining.lastIndex(where: { folderIDs.contains($0.id) }) else { continue }
            if let outer = parent.parentTrackID { moving[root].parentTrackID = outer }
            else { moving[root].detachFromGroup() }
            remaining.insert(contentsOf: moving, at: last + 1)
            songs[song].tracks = remaining
        }
        orderSpecialTracks()
    }
    mutating func ungroupTrack(_ id: UUID) {
        for song in songs.indices {
            let parent = songs[song].tracks.first { $0.id == id }?.parentTrackID
            for track in songs[song].tracks.indices where songs[song].tracks[track].parentTrackID == id {
                if let parent { songs[song].tracks[track].parentTrackID = parent }
                else { songs[song].tracks[track].detachFromGroup() }
            }
        }
        orderSpecialTracks()
    }
    mutating func deleteTracks(_ ids: Set<UUID>) {
        for song in songs.indices { for id in ids { songs[song].unlinkTracks(id) } }
        for id in ids { ungroupTrack(id) }
        for song in songs.indices {
            songs[song].tracks.removeAll { ids.contains($0.id) }
            for index in songs[song].tracks.indices {
                guard var routing = songs[song].tracks[index].routing else { continue }
                routing.receives = routing.receives.map { $0.flatMap { ids.contains($0) ? nil : $0 } }
                routing.transmitters = routing.transmitters.map { $0.flatMap { ids.contains($0) ? nil : $0 } }
                songs[song].tracks[index].routing = routing
            }
        }
        orderSpecialTracks()
    }
    mutating func deleteRegion(_ id: UUID) {
        let childIDs = Set(songs.flatMap(\.parts).filter { $0.parentRegionID == id }.map(\.id))
        if !childIDs.isEmpty {
            // Deleting the special wrapper restores its songs and their edited markers.
            _ = try? disunifyRegion(id)
            return
        }
        for song in songs.indices { songs[song].markers?.removeAll { $0.unifiedRegionID == id } }
        for song in songs.indices { songs[song].parts.removeAll { $0.id == id } }
        if var state = regionSetlist {
            for index in state.playlists.indices { Self.removeRegion(id, from: &state, playlist: state.playlists[index].id) }
            if var blocks = state.blocks {
                for index in blocks.indices where blocks[index].beforeRegionId == id { blocks[index].beforeRegionId = nil }
                state.blocks = blocks
            }
            regionSetlist = state
        }
        // Timecode items are derived from regions, never independently edited.
        let timecodeID = Self.timecodeItemID(id)
        for song in songs.indices {
            for track in songs[song].tracks.indices where songs[song].tracks[track].kind == .timecode {
                songs[song].tracks[track].clips.removeAll { $0.id == timecodeID }
            }
        }
    }
    mutating func removeRegion(_ id: UUID, from playlist: UUID) {
        guard var state = regionSetlist else { return }
        Self.removeRegion(id, from: &state, playlist: playlist)
        regionSetlist = state
    }
    /// Drawer songs are owned by their unified region. Only top-level rows and
    /// blocks in the current list can be removed, in one undoable edit.
    mutating func deleteSetlistEntries(_ ids: Set<UUID>, song songID: UUID, playlist: UUID?) {
        guard let song = songs.first(where: { $0.id == songID }) else { return }
        let listed: Set<UUID>
        if let playlist {
            guard let list = regionSetlist?.playlists.first(where: { $0.id == playlist && $0.songId == songID }) else { return }
            listed = Set(list.regionIds)
        } else { listed = Set(song.parts.map(\.id)) }
        let regions = song.parts.filter { $0.parentRegionID == nil && ids.contains($0.id) && listed.contains($0.id) }.map(\.id)
        regionSetlist?.blocks?.removeAll { ids.contains($0.id) && $0.songId == songID && $0.playlistId == playlist }
        for id in regions {
            if let playlist { removeRegion(id, from: playlist) }
            else { deleteRegion(id) }
        }
    }
    private static func removeRegion(_ id: UUID, from state: inout RegionSetlist, playlist: UUID) {
        guard let index = state.playlists.firstIndex(where: { $0.id == playlist }),
              let position = state.playlists[index].regionIds.firstIndex(of: id) else { return }
        let following = state.playlists[index].regionIds.dropFirst(position + 1).first
        state.playlists[index].regionIds.removeAll { $0 == id }
        if var blocks = state.blocks {
            for index in blocks.indices where blocks[index].playlistId == playlist && blocks[index].beforeRegionId == id {
                blocks[index].beforeRegionId = following
            }
            state.blocks = blocks
        }
    }
    var mediaPaths: Set<String> {
        Set(songs.flatMap(\.tracks).flatMap { track in track.clips.compactMap { $0.audioFile?.path } + [track.audioFile?.path, track.clickSound?.path].compactMap { $0 } })
    }
}

private extension Track {
    mutating func sendToGroup(_ parent: UUID) {
        var patches = outputPatches
        if patches.isEmpty { patches = [.masterGroup] }
        patches[0] = .masterGroup
        patches = [.masterGroup] + patches.dropFirst().filter { $0 != .master && $0 != .masterGroup }
        parentTrackID = parent
        patch = patches[0]; secondaryPatch = patches.count > 1 ? patches[1] : nil
        if outputs != nil { outputs = patches }
    }
    mutating func detachFromGroup() {
        if let outputs { self.outputs = outputs.map { $0 == .masterGroup ? .master : $0 } }
        if patch == .masterGroup { patch = .master }
        if secondaryPatch == .masterGroup { secondaryPatch = .master }
        parentTrackID = nil
    }
}

/// Bounded project history: no PCM or source-file copies, no work on audio callbacks.
public struct ProjectEditHistory {
    private var baseline: Project
    private var past: [Project] = []
    private var future: [Project] = []
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public init(_ project: Project) { baseline = project }
    public mutating func record(_ project: Project, preservingMediaStorage: Bool = false) {
        guard project != baseline else { return }
        past.append(baseline); if past.count > 100 { past.removeFirst() }
        // Mixer controls already retain immutable clip/waveform storage.
        // Preserve that storage directly instead of visiting every project item.
        if preservingMediaStorage { baseline = project; future.removeAll(); return }
        var compact = project
        let previous = Dictionary(uniqueKeysWithValues: baseline.songs.flatMap(\.tracks).flatMap(\.clips).map { ($0.id, $0) })
        for song in compact.songs.indices {
            for track in compact.songs[song].tracks.indices {
                for index in compact.songs[song].tracks[track].clips.indices {
                    let clip = compact.songs[song].tracks[track].clips[index]
                    if let old = previous[clip.id], old.audioFile == clip.audioFile, old.sourceOffset == clip.sourceOffset,
                       old.duration == clip.duration, old.waveform.count == clip.waveform.count {
                        compact.songs[song].tracks[track].clips[index].waveform = old.waveform
                        compact.songs[song].tracks[track].clips[index].waveformChannels = old.waveformChannels
                    }
                }
            }
        }
        baseline = compact; future.removeAll()
    }
    public mutating func undo() -> Project? {
        guard let project = past.popLast() else { return nil }
        future.append(baseline); baseline = project; return project
    }
    public mutating func redo() -> Project? {
        guard let project = future.popLast() else { return nil }
        past.append(baseline); baseline = project; return project
    }
}

public extension AudioClip {
    /// Both edges follow the same original source interval, including backward extension.
    func resized(start: Double, end: Double) -> AudioClip {
        guard start.isFinite, end.isFinite, start >= 0, end - start >= 0.01 else { return self }
        var clip = self
        if var midi = clip.midi {
            let offset = clip.sourceOffset + (start - clip.startTime) * clip.audioRate
            if offset < 0 { for index in midi.notes.indices { midi.notes[index].start -= offset * midi.sourceBPM / 60 } }
            clip.sourceOffset = max(0, offset); clip.midi = midi
            clip.startTime = start; clip.duration = end - start
            return clip
        }
        let loopStart = clip.loopStart ?? clip.sourceOffset
        let loopLength = clip.loopLength ?? clip.duration * clip.audioRate
        clip.loopStart = loopStart; clip.loopLength = loopLength
        let offset = clip.sourceOffset - loopStart + (start - clip.startTime) * clip.audioRate
        clip.sourceOffset = loopStart + ((offset.truncatingRemainder(dividingBy: loopLength) + loopLength).truncatingRemainder(dividingBy: loopLength))
        clip.startTime = start; clip.duration = end - start
        return clip
    }
}

/// Restores audio at the relative paths already stored in a project. Keeping
/// those paths means opening and saving with missing clips never discards them.
public enum ProjectAudioRecovery {
    public struct Result: Sendable {
        public let recovered: [String]
        public let remaining: [String]
        public let errors: [String]
    }

    public static func missingPaths(in project: Project, directory: URL) -> [String] {
        let paths = Set(project.songs.flatMap(\.tracks).flatMap { track in
            [track.audioFile?.path, track.clickSound?.path].compactMap { $0 } + track.clips.compactMap { $0.audioFile?.path }
        })
        return paths.filter { path in
            let url = directory.appendingPathComponent(path)
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func restore(_ project: Project, directory: URL, searching folder: URL) throws -> Result {
        let missing = missingPaths(in: project, directory: directory)
        guard !missing.isEmpty else { return Result(recovered: [], remaining: [], errors: []) }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw ProjectError.invalid("Could not search the selected folder.")
        }
        var candidates: [String: [URL]] = [:]
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            candidates[url.lastPathComponent.lowercased(), default: []].append(url)
        }
        var recovered: [String] = [], errors: [String] = []
        for path in missing {
            try Task.checkCancellation()
            let matches = candidates[URL(fileURLWithPath: path).lastPathComponent.lowercased()] ?? []
            let exact = matches.filter { $0.path.lowercased().hasSuffix("/" + path.lowercased()) }
            guard let source = (exact.count == 1 ? exact : matches.count == 1 ? matches : []).first else { continue }
            let destination = directory.appendingPathComponent(path)
            let temporary = destination.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".recovering")
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: temporary)
                try fm.moveItem(at: temporary, to: destination)
                recovered.append(path)
            } catch {
                try? fm.removeItem(at: temporary)
                errors.append("\(path): \(error.localizedDescription)")
            }
        }
        return Result(recovered: recovered, remaining: missingPaths(in: project, directory: directory), errors: errors)
    }
}
