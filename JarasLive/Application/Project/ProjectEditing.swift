import Foundation

public enum GridDeleteTarget: Equatable {
    case items(Set<UUID>), tracks(Set<UUID>), none
    public init(items: Set<UUID>, tracks: Set<UUID>) {
        self = !items.isEmpty ? .items(items) : !tracks.isEmpty ? .tracks(tracks) : .none
    }
    public init(items: Set<UUID>, tracks: Set<UUID>, song: Song, visibility: TrackVisibilityState) {
        let gridTracks = visibility.visibleTracks(in: song.tracks, area: .trackMixer)
        let mixerTracks = visibility.visibleTracks(in: song.tracks, area: .barMixer)
            .filter { $0.kind == .standard || $0.kind == .click }
        // Both mixers share the track selection. A track selected in the bottom
        // mixer remains the delete target even when its grid row is hidden.
        let selectable = Set(gridTracks.map(\.id)).union(mixerTracks.map(\.id))
        self.init(items: items.intersection(gridTracks.flatMap(\.clips).map(\.id)),
                  tracks: tracks.intersection(selectable))
    }
}

public enum TimelineBulkDeletion: String, CaseIterable, Identifiable {
    case tempo, regions, markers
    public var id: String { rawValue }
    public func matches(_ marker: TimelineMarker) -> Bool {
        if marker.unifiedRegionID != nil || marker.sourceRegionID != nil { return self == .regions }
        return self == .tempo ? marker.tempoBPM != nil : self == .markers && marker.tempoBPM == nil
    }
}

/// Matches VS Hook's Converter for markers outside existing regions.
public struct MarkerRegionConversion {
    public struct Plan { public let marker: TimelineMarker; public let end: Double }
    public let plans: [Plan]
    public let skipped: [String]
    public var message: String {
        let summary = "\(plans.count) marcador(es) convertido(s) em região."
        return skipped.isEmpty ? summary : summary + "\n\nNão convertidos:\n" + skipped.joined(separator: "\n")
    }
    public static func outsideRegions(_ marker: TimelineMarker, in song: Song) -> Bool {
        marker.tempoBPM == nil && marker.unifiedRegionID == nil && marker.sourceRegionID == nil &&
        !song.parts.contains { marker.position >= $0.startTime - 0.000001 && marker.position < $0.endTime - 0.000001 }
    }
    private static func reserved(_ marker: TimelineMarker) -> Bool {
        let name = marker.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let loop = name.hasPrefix("*") ? Int(name.dropFirst().drop(while: { $0.isWhitespace }).prefix(while: { $0.isNumber })) : nil
        return marker.isSection || marker.isLoopSection || name.hasPrefix("$") || name.hasPrefix("!") || loop == 1 || loop == 2
    }
    public init(song: Song, markerID: UUID? = nil) {
        let epsilon = 0.000001
        let markers = (song.markers ?? []).sorted { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }
        let audio = song.tracks.flatMap(\.clips).filter { $0.audioFile != nil && $0.midi == nil && $0.duration > epsilon }
        func audioEnd(_ position: Double) -> Double? {
            audio.filter { abs($0.startTime - position) <= epsilon }.map { $0.startTime + $0.duration }.max()
        }
        func ordinary(_ marker: TimelineMarker) -> Bool {
            marker.tempoBPM == nil && marker.unifiedRegionID == nil && marker.sourceRegionID == nil && !Self.reserved(marker) && !marker.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var plans: [Plan] = [], skipped: [String] = []
        for marker in markers where markerID == nil || marker.id == markerID {
            // Tempo and unified-region heads are not ordinary markers.
            if markerID == nil && (marker.tempoBPM != nil || marker.unifiedRegionID != nil || marker.sourceRegionID != nil) { continue }
            let name = marker.name.trimmingCharacters(in: .whitespacesAndNewlines)
            var reason: String?
            if !Self.outsideRegions(marker, in: song) { reason = "Já pertence a uma região ou é um marcador de tempo. Use um marcador comum fora das regiões." }
            else if Self.reserved(marker) { reason = "Marcador reservado para Parts/loops ou desativado. Use um marcador comum, sem os prefixos $, !, *1 ou *2." }
            else if name.isEmpty { reason = "O marcador está sem nome. Edite o marcador e dê um nome antes de converter." }
            else if let end = audioEnd(marker.position) {
                var limit = end
                for region in song.parts where region.startTime > marker.position + epsilon { limit = min(limit, region.startTime) }
                for next in markers where next.position > marker.position + epsilon && ordinary(next) && audioEnd(next.position) != nil { limit = min(limit, next.position) }
                if plans.contains(where: { abs($0.marker.position - marker.position) <= epsilon }) {
                    reason = "Outro marcador já será convertido neste ponto. Mova este marcador para o início de outro item de áudio."
                } else if limit > marker.position + epsilon { plans.append(Plan(marker: marker, end: limit)) }
                else { reason = "Não há duração disponível para a região. Ajuste o áudio ou o início da próxima região." }
            } else { reason = "Nenhum item de áudio começa neste ponto. Alinhe o marcador ao início de um item de áudio com duração maior que zero." }
            if let reason { skipped.append("\(name.isEmpty ? "Sem nome" : name): \(reason)") }
        }
        if plans.isEmpty && skipped.isEmpty { skipped.append("Não há marcadores comuns nesta timeline. Crie um marcador no início de um item de áudio, fora das regiões.") }
        self.plans = plans; self.skipped = skipped
    }
}

public extension Project {
    @discardableResult mutating func convertMarkersToRegions(song songID: UUID, markerID: UUID? = nil) -> MarkerRegionConversion? {
        guard let index = songs.firstIndex(where: { $0.id == songID }) else { return nil }
        let result = MarkerRegionConversion(song: songs[index], markerID: markerID)
        for plan in result.plans {
            var part = Part(id: UUID(), name: plan.marker.name, startTime: plan.marker.position, endTime: plan.end)
            part.color = plan.marker.color
            songs[index].parts.append(part)
        }
        let converted = Set(result.plans.map { $0.marker.id })
        songs[index].markers?.removeAll { converted.contains($0.id) }
        return result
    }

    mutating func deleteTimelineElements(_ kind: TimelineBulkDeletion, song songID: UUID) {
        guard let index = songs.firstIndex(where: { $0.id == songID }) else { return }
        if kind == .regions {
            let regions = songs[index].parts
            let ids = Set(regions.map(\.id))
            // Remove members before wrappers: bulk deletion must not disunify them.
            for part in regions.sorted(by: { ($0.parentRegionID != nil ? 0 : 1) < ($1.parentRegionID != nil ? 0 : 1) }) { deleteRegion(part.id) }
            for track in songs[index].tracks.indices {
                for item in songs[index].tracks[track].clips.indices {
                    if let owner = songs[index].tracks[track].clips[item].regionOwnerID, ids.contains(owner) { songs[index].tracks[track].clips[item].regionOwnerID = nil }
                }
            }
            if var markers = songs[index].markers {
                for item in markers.indices { if let owner = markers[item].regionOwnerID, ids.contains(owner) { markers[item].regionOwnerID = nil } }
                songs[index].markers = markers
            }
            regionSetlist?.playedLiveRegionIDs?.removeAll { ids.contains($0) }
        }
        let removed = Set((songs[index].markers ?? []).filter { kind.matches($0) }.map(\.id))
        songs[index].markers?.removeAll { removed.contains($0.id) }
        for part in songs[index].parts.indices {
            songs[index].parts[part].multiLoops?.removeAll { removed.contains($0.marker1) || removed.contains($0.marker2) }
        }
    }

    /// A track copy owns its editable state while reusing immutable media files.
    /// Folders include their descendants; linked stereo channels stay a pair.
    @discardableResult mutating func duplicateTracks(_ ids: Set<UUID>, song songID: UUID) throws -> Set<UUID> {
        guard let index = songs.firstIndex(where: { $0.id == songID }) else { return [] }
        let source = songs[index], selected = source.trackDuplicationTargets(ids)
        guard !selected.isEmpty else { return [] }
        let hierarchy = TrackHierarchy(source.tracks)
        let roots = source.tracks.filter { selected.contains($0.id) && Set(hierarchy.ancestors(of: $0.id)).isDisjoint(with: selected) }
        let rootIDs = Set(roots.map(\.id))
        let mapping = Dictionary(uniqueKeysWithValues: source.tracks.filter { selected.contains($0.id) }.map { ($0.id, UUID()) })
        func mapped(_ id: UUID) -> UUID { mapping[id] ?? id }
        func routing(_ value: TrackRouting?) -> TrackRouting? {
            value.map { TrackRouting(receives: $0.receives.map { $0.map(mapped) }, transmitters: $0.transmitters.map { $0.map(mapped) }) }
        }
        var copies: [UUID: Track] = [:]
        let connections = source.trackConnections.sorted {
            $0.source == $1.source ? $0.destination.uuidString < $1.destination.uuidString : $0.source.uuidString < $1.source.uuidString
        }
        for original in source.tracks where selected.contains(original.id) {
            var copy = original
            copy.id = mapped(original.id)
            copy.parentTrackID = original.parentTrackID.map(mapped)
            copy.routing = routing(original.routing)
            if var link = copy.stereoLink {
                link.partner = mapped(link.partner); link.original.routing = routing(link.original.routing)
                copy.stereoLink = link
            }
            // A connection can be stored only on the opposite endpoint. Carry
            // it onto the new endpoint without modifying the original tracks.
            for edge in connections where edge.source == original.id || edge.destination == original.id {
                var routes = copy.routing ?? TrackRouting()
                if edge.source == original.id {
                    let destination = mapped(edge.destination)
                    if !routes.transmitters.contains(destination) { routes.transmitters.append(destination) }
                } else {
                    let sender = mapped(edge.source)
                    if !routes.receives.contains(sender) { routes.receives.append(sender) }
                }
                copy.routing = routes
            }
            var trackFX = TrackCopyFXIdentities()
            copy.fx = original.fx.map { trackFX.copy($0) }
            copy.automation = trackFX.copy(original.automation)
            copy.clips = original.clips.map { original in
                var clip = original
                clip.id = UUID()
                clip.separatedStemTracks = original.separatedStemTracks?.map(mapped)
                if var midi = clip.midi {
                    for note in midi.notes.indices { midi.notes[note].id = UUID() }
                    clip.midi = midi
                }
                var clipFX = TrackCopyFXIdentities()
                clip.fx = original.fx.map { clipFX.copy($0) }
                clip.automation = clipFX.copy(original.automation)
                return clip
            }
            copies[original.id] = copy
        }
        // Insert each complete subtree after its source. Child copies retain
        // the same parent when that parent was outside the selection.
        var insertions: [Int: [Track]] = [:], handled: Set<UUID> = []
        for root in roots where !handled.contains(root.id) {
            var block = hierarchy.descendants(of: root.id).union([root.id])
            handled.insert(root.id)
            if let partner = root.stereoLink?.partner, rootIDs.contains(partner),
               source.tracks.first(where: { $0.id == partner })?.parentTrackID == root.parentTrackID {
                block.formUnion(hierarchy.descendants(of: partner).union([partner])); handled.insert(partner)
            }
            let positions = source.tracks.indices.filter { block.contains(source.tracks[$0].id) }
            if let last = positions.last { insertions[last, default: []] += positions.compactMap { copies[source.tracks[$0].id] } }
        }
        var candidate = self
        candidate.songs[index].tracks = source.tracks.enumerated().flatMap { [$0.element] + (insertions[$0.offset] ?? []) }
        // Explicit region pitch selections and multi-loop mixer rules are part
        // of the track's sound. Nil pitch lists already include all tracks.
        for part in candidate.songs[index].parts.indices {
            if let tracks = source.parts[part].pitchTrackIDs { candidate.songs[index].parts[part].pitchTrackIDs = tracks + tracks.compactMap { mapping[$0] } }
            if let groups = source.parts[part].pitchGroupIDs { candidate.songs[index].parts[part].pitchGroupIDs = groups + groups.compactMap { mapping[$0] } }
            if var loops = source.parts[part].multiLoops {
                for loop in loops.indices {
                    loops[loop].tracks += loops[loop].tracks.compactMap { original -> MultiLoopTrack? in
                        guard let id = mapping[original.id] else { return nil }
                        var copy = original; copy.id = id; return copy
                    }
                }
                candidate.songs[index].parts[part].multiLoops = loops
            }
        }
        try candidate.validate()
        self = candidate
        return Set(mapping.values)
    }
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
        // The wrapper covers complete songs, including silence before their
        // first item. Media placement must never trim the first drawer entry.
        let originalFlags = (songs[songIndex].markers ?? []).filter { $0.unifiedRegionID.map(rootIDs.contains) == true }
        let start = (roots.map(\.startTime) + members.map(\.startTime) + originalFlags.map(\.position)).min()!
        let end = (roots.map(\.endTime) + members.map(\.endTime)).max()!
        var originalMarkers: [UUID: TimelineMarker] = [:]
        for marker in originalFlags where marker.unifiedRegionID.map(replacedGroups.contains) == true {
            guard let source = marker.sourceRegionID else { continue }
            guard originalMarkers.updateValue(marker, forKey: source) == nil else {
                throw ProjectError.invalid("More than one unified marker refers to the same song. Resolve the duplicate markers before unifying these regions.")
            }
        }
        var group = existingGroup ?? Part(id: UUID(), name: name, startTime: start, endTime: end, color: first.color)
        group.startTime = start; group.endTime = end
        songs[songIndex].parts.removeAll { replacedGroups.contains($0.id) }
        let memberIDs = Set(members.map(\.id))
        for index in songs[songIndex].parts.indices where memberIDs.contains(songs[songIndex].parts[index].id) {
            songs[songIndex].parts[index].parentRegionID = group.id
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
        markers.removeAll { $0.unifiedRegionID.map(replacedGroups.contains) == true }
        markers += members.map { TimelineMarker(id: UUID(), name: originalMarkers[$0.id]?.name ?? $0.name, position: originalMarkers[$0.id]?.position ?? $0.startTime, color: originalMarkers[$0.id]?.color ?? $0.color ?? 0x54ff93, unifiedRegionID: group.id, sourceRegionID: $0.id) }
        songs[songIndex].markers = markers
        if var state = regionSetlist {
            for index in state.playlists.indices where state.playlists[index].songId == songs[songIndex].id {
                var inserted = false
                state.playlists[index].duplicates = state.playlists[index].duplicates?.map { alias in
                    var alias = alias
                    if rootIDs.contains(alias.regionId) || memberIDs.contains(alias.regionId) { alias.regionId = group.id }
                    return alias
                }
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
                candidate.songs[song].tracks[track].clips[clip].regionOwnerID = remaining.regionOwner(at: item.startTime)
            }
        }
        for index in (remaining.markers ?? []).indices where remaining.markers?[index].regionOwnerID == id {
            candidate.songs[song].markers?[index].regionOwnerID = remaining.regionOwner(at: remaining.markers![index].position)
        }
        if var state = candidate.regionSetlist {
            for index in state.playlists.indices {
                let prior = state.playlists[index]
                var duplicates = (prior.duplicates ?? []).filter { $0.regionId != id }
                state.playlists[index].regionIds = prior.regionIds.flatMap { entry -> [UUID] in
                    if entry == id { return members.map(\.id) }
                    guard prior.isDuplicate(entry), prior.regionSourceID(forEntry: entry) == id else { return [entry] }
                    return members.enumerated().map { offset, member in
                        let alias = RegionPlaylistDuplicate(id: offset == 0 ? entry : UUID(), regionId: member.id)
                        duplicates.append(alias)
                        return alias.id
                    }
                }
                state.playlists[index].duplicates = duplicates.isEmpty ? nil : duplicates
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
        let order: [TrackKind] = [.timecode, .teleprompt, .teleprompt2, .chords, .click, .video, .standard]
        for song in songs.indices {
            let tracks = songs[song].tracks
            func rank(_ track: Track) -> Int { track.role.rawValue == "vinhetas" ? 7 : order.firstIndex(of: track.kind)! * 2 }
            let ranks = tracks.map(rank)
            guard zip(ranks, ranks.dropFirst()).contains(where: { $0.0 > $0.1 }) else { continue }
            songs[song].tracks = tracks.enumerated().sorted { lhs, rhs in
                rank(lhs.element) == rank(rhs.element) ? lhs.offset < rhs.offset : rank(lhs.element) < rank(rhs.element)
            }.map(\.element)
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
                if songs[song].tracks[track].clips[index].isProjectionMedia {
                    songs[song].tracks[track].clips[index] = songs[song].tracks[track].clips[index].resized(start: start, end: end)
                } else if songs[song].tracks[track].kind == .timecode {
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
                    songs[song].tracks[track].clips[index] = songs[song].tracks[track].clips[index].resized(start: start, end: end)
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
                    if textTrack && !clip.isProjectionMedia && clip.loopLength == nil { return [left, right] }
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
            for track in songs[song].tracks.indices {
                let timecode = songs[song].tracks[track].kind == .timecode
                songs[song].tracks[track].clips.removeAll { ids.contains($0.id) && (!timecode || $0.isProjectionMedia) }
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
            for index in state.playlists.indices { Self.removeRegion(id, from: &state, playlist: state.playlists[index].id, includingDuplicates: true) }
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
        let regions: [UUID]
        if let playlist {
            guard let list = regionSetlist?.playlists.first(where: { $0.id == playlist && $0.songId == songID }) else { return }
            regions = list.regionIds.filter { ids.contains($0) && list.region(forEntry: $0, in: song)?.parentRegionID == nil }
        } else { regions = song.parts.filter { $0.parentRegionID == nil && ids.contains($0.id) }.map(\.id) }
        regionSetlist?.blocks?.removeAll { ids.contains($0.id) && $0.songId == songID && $0.playlistId == playlist }
        for id in regions {
            if let playlist { removeRegion(id, from: playlist) }
            else { deleteRegionWithContents(id, song: songID) }
        }
    }
    /// All Regions deletes the song and its owned timeline content together.
    /// Resolve ownership before removing the region tree: overlap alone must
    /// never delete another song's content. Unassigned tempo points are also
    /// cleared inside the deleted span, including points saved by earlier builds
    /// without ownership; this deletion rule does not attach them during moves.
    private mutating func deleteRegionWithContents(_ id: UUID, song songID: UUID) {
        guard let index = songs.firstIndex(where: { $0.id == songID }),
              songs[index].parts.contains(where: { $0.id == id }) else { return }
        let source = songs[index]
        var removed: Set<UUID> = [id]
        var pending = [id]
        while let parent = pending.popLast() {
            for child in source.parts where child.parentRegionID == parent && removed.insert(child.id).inserted {
                pending.append(child.id)
            }
        }
        let timecodeIDs = Set(removed.map(Self.timecodeItemID))
        for track in songs[index].tracks.indices {
            let nativeTimecode = source.tracks[track].kind == .timecode
            songs[index].tracks[track].clips.removeAll { clip in
                (nativeTimecode && timecodeIDs.contains(clip.id)) || removed.contains { source.itemBelongs(clip, to: $0) }
            }
        }
        let removedSpans = source.parts.filter { removed.contains($0.id) }
        songs[index].markers?.removeAll { marker in
            if removed.contains(where: { source.markerBelongs(marker, to: $0) }) { return true }
            return marker.isTempo && marker.regionOwnerID == nil && removedSpans.contains {
                marker.position >= $0.startTime && marker.position < $0.endTime
            }
        }
        songs[index].parts.removeAll { removed.contains($0.id) }
        if var state = regionSetlist {
            // Keep surviving playlist order and move block anchors to the next
            // surviving song, exactly as when removing a playlist entry.
            for region in source.parts where removed.contains(region.id) {
                for playlist in state.playlists { Self.removeRegion(region.id, from: &state, playlist: playlist.id, includingDuplicates: true) }
            }
            if var blocks = state.blocks {
                for block in blocks.indices where blocks[block].songId == songID && blocks[block].playlistId == nil && blocks[block].beforeRegionId.map(removed.contains) == true {
                    blocks[block].beforeRegionId = nil
                }
                state.blocks = blocks
            }
            regionSetlist = state
        }
    }
    private static func removeRegion(_ id: UUID, from state: inout RegionSetlist, playlist: UUID, includingDuplicates: Bool = false) {
        guard let index = state.playlists.firstIndex(where: { $0.id == playlist }) else { return }
        let list = state.playlists[index]
        let removed = Set(list.regionIds.filter { $0 == id || (includingDuplicates && list.regionSourceID(forEntry: $0) == id) })
        guard !removed.isEmpty else { return }
        state.playlists[index].regionIds.removeAll { removed.contains($0) }
        state.playlists[index].duplicates?.removeAll { removed.contains($0.id) }
        if state.playlists[index].duplicates?.isEmpty == true { state.playlists[index].duplicates = nil }
        if var blocks = state.blocks {
            for index in blocks.indices where blocks[index].playlistId == playlist {
                guard let anchor = blocks[index].beforeRegionId, removed.contains(anchor),
                      let position = list.regionIds.firstIndex(of: anchor) else { continue }
                blocks[index].beforeRegionId = list.regionIds.dropFirst(position + 1).first { !removed.contains($0) }
            }
            state.blocks = blocks
        }
    }
    var mediaPaths: Set<String> {
        var paths = Set(songs.flatMap(\.tracks).flatMap { track in track.clips.compactMap { $0.audioFile?.path } + [track.audioFile?.path, track.clickSound?.path].compactMap { $0 } })
        paths.formUnion(masterFX?.samplePaths ?? [])
        for track in songs.flatMap(\.tracks) {
            paths.formUnion(track.fx?.samplePaths ?? [])
            for clip in track.clips { paths.formUnion(clip.fx?.samplePaths ?? []) }
        }
        return paths
    }
}

public extension Song {
    /// Master and special singleton lanes have no duplication action.
    func trackDuplicationTargets(_ ids: Set<UUID>) -> Set<UUID> {
        let eligible = Set(tracks.filter { $0.kind == .standard && $0.role.rawValue != "vinhetas" }.map(\.id))
        let hierarchy = TrackHierarchy(tracks)
        var result = ids.intersection(eligible), previous: Set<UUID> = []
        while result != previous {
            previous = result
            for track in tracks where previous.contains(track.id) {
                result.formUnion(hierarchy.descendants(of: track.id).intersection(eligible))
                if let partner = track.stereoLink?.partner, eligible.contains(partner) { result.insert(partner) }
            }
        }
        return result
    }
}

/// Effect keys and EQ-band references must travel with their automation. The
/// plugin's opaque component/controller state is copied byte for byte.
private struct TrackCopyFXIdentities {
    private var effects: [String: String] = [:]
    private var plugins: [String: String] = [:]
    private var bands: [String: [UUID: UUID]] = [:]
    mutating func copy(_ original: NativeFXSettings) -> NativeFXSettings {
        var result = original
        func copyBands(_ original: [EQBand]) -> (values: [EQBand], ids: [UUID: UUID]) {
            var ids: [UUID: UUID] = [:]
            let values = original.map { band -> EQBand in var copy = band; copy.id = UUID(); ids[band.id] = copy.id; return copy }
            return (values, ids)
        }
        let base = copyBands(original.bands); result.bands = base.values; bands["EQ"] = base.ids
        if let instances = original.instances {
            result.instances = instances.map { instance in
                var copy = instance; copy.id = UUID().uuidString
                effects[instance.effectKey] = copy.effectKey
                let nested = copyBands(instance.settings.bands)
                copy.settings.bands = nested.values; bands[instance.effectKey] = nested.ids
                return copy
            }
        }
        if let external = original.externalPlugins {
            result.externalPlugins = external.map { plugin in
                var copy = plugin; copy.id = UUID().uuidString
                effects[plugin.effectKey] = copy.effectKey; plugins[plugin.id] = copy.id
                return copy
            }
        }
        result.inserted = original.inserted.map { effects[$0] ?? $0 }
        return result
    }
    func copy(_ original: TrackAutomation?) -> TrackAutomation? {
        guard var result = original else { return nil }
        for index in result.envelopes.indices {
            result.envelopes[index].id = UUID()
            for point in result.envelopes[index].points.indices { result.envelopes[index].points[point].id = UUID() }
            if var native = result.envelopes[index].target.native {
                native.band = native.band.map { bands[native.effect]?[$0] ?? $0 }
                native.effect = effects[native.effect] ?? native.effect
                result.envelopes[index].target.native = native
            }
            if let plugin = result.envelopes[index].target.plugin { result.envelopes[index].target.plugin = plugins[plugin] ?? plugin }
        }
        return result
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
        if clip.audioFile != nil && clip.loopLength == nil {
            let actualStart = max(start, clip.startTime - clip.sourceOffset / clip.audioRate)
            guard end - actualStart >= 0.01 else { return self }
            clip.sourceOffset = max(0, clip.sourceOffset + (actualStart - clip.startTime) * clip.audioRate)
            clip.startTime = actualStart; clip.duration = end - actualStart
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
        let paths = project.mediaPaths
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

public extension Song {
    /// One translation for the entire selection; reject an incompatible destination atomically.
    func movingItems(_ ids: Set<UUID>, anchor: UUID, start: Double, track destination: UUID?) -> Song? {
        guard start.isFinite, let source = tracks.firstIndex(where: { $0.clips.contains { $0.id == anchor } }),
              let item = tracks[source].clips.first(where: { $0.id == anchor }) else { return nil }
        let target = destination.flatMap { id in tracks.firstIndex(where: { $0.id == id }) } ?? source
        let rows = target - source
        let selected = tracks.enumerated().flatMap { row, track in track.clips.filter { ids.contains($0.id) }.map { (row, $0) } }
        guard !selected.isEmpty else { return nil }
        let delta = max(start - item.startTime, -(selected.map { $0.1.startTime }.min() ?? 0))
        var result = self
        for row in result.tracks.indices { result.tracks[row].clips.removeAll { ids.contains($0.id) } }
        for (row, original) in selected {
            let to = row + rows
            guard tracks.indices.contains(to), tracks[row].kind != .timecode,
                  row == to || (tracks[row].kind == .standard && tracks[to].kind == .standard) || original.isProjectionMedia else { return nil }
            var clip = original; clip.startTime += delta
            guard result.tracks[to].canPlaceItem(start: clip.startTime, duration: clip.duration, media: clip.isProjectionMedia) else { return nil }
            clip.regionOwnerID = regionOwner(at: clip.startTime)
            result.tracks[to].clips.append(clip)
            result.duration = max(result.duration, clip.startTime + clip.duration)
        }
        return result
    }
}

public extension Project {
    mutating func remapFXSamples(_ mapping: [String:String]) {
        masterFX?.remapSamples(mapping)
        for s in songs.indices { for t in songs[s].tracks.indices {
            songs[s].tracks[t].fx?.remapSamples(mapping)
            for c in songs[s].tracks[t].clips.indices { songs[s].tracks[t].clips[c].fx?.remapSamples(mapping) }
        }}
    }
}
