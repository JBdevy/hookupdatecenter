import Foundation

/// VS Hook's project ExtState, read from the RPP rather than machine preferences.
/// REAPER marker numbers and region numbers are separate namespaces.
struct VSHookProjectMigration {
    struct SourceMarker { let number: String; let marker: TimelineMarker }
    let state: [String: [String: String]]
    var regionIDs: [String: UUID] = [:]
    var trackIDs: [String: UUID] = [:]
    var sourceMarkers: [SourceMarker] = []
    private var playlistState: [String: String] { state["CHATGPT_REGION_PLAYLIST"] ?? [:] }
    private var loopState: [String: String] { state["VS_HOOK_MULTILOOPS"] ?? [:] }
    var hasMetadata: Bool { !state.isEmpty }

    func isTechnicalMarker(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.hasPrefix("*") || name.hasPrefix("$") || (hasMetadata && name.hasPrefix("!"))
    }
    private static func unescape(_ text: String) -> String {
        let chars = Array(text); var result = "", index = 0
        while index < chars.count {
            if chars[index] == "\\", index + 1 < chars.count,
               let replacement: Character = ["p": "|", "t": "\t", "n": "\n", "\\": "\\"][chars[index + 1]] {
                result.append(replacement); index += 2
            } else { result.append(chars[index]); index += 1 }
        }
        return result
    }
    private static func rows(_ text: String) -> [[String]] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .newlines).components(separatedBy: "\t") }
    }
    private func markerPart(_ marker: SourceMarker, in song: Song) -> Part? {
        guard !isTechnicalMarker(marker.marker.name) else { return nil }
        return song.parts.first { $0.parentRegionID != nil && abs($0.startTime - marker.marker.position) <= 0.000001 }
    }

    func apply(to project: inout Project, warnings: inout Set<String>) {
        guard var song = project.songs.first else { return }
        let marked = song.tracks.filter { $0.kind == .standard && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") }
        guard hasMetadata || !marked.isEmpty || sourceMarkers.contains(where: { $0.marker.name.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("*") }) else { return }
        let groups = Set(song.tracks.compactMap(\.parentTrackID))
        let pitchTracks = marked.filter { !groups.contains($0.id) }.map(\.id)
        let pitchGroups = marked.filter { groups.contains($0.id) }.map(\.id)
        if marked.contains(where: { $0.parentTrackID.map(pitchGroups.contains) ?? false }) {
            warnings.insert("VS Hook: uma pasta e uma pista filha estão marcadas com #. O CatLive aplica a transposição uma única vez; revise essa seleção.")
        }
        var offsets: [String: Int] = [:]
        for field in (playlistState["TUNER_OFFSETS_V1"] ?? "").components(separatedBy: "|") {
            let pair = field.components(separatedBy: "=")
            if pair.count == 2, let value = Int(pair[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                offsets[pair[0].trimmingCharacters(in: .whitespacesAndNewlines)] = min(12, max(-12, value))
            }
        }
        var sourceNumbers = Dictionary(uniqueKeysWithValues: regionIDs.map { ($0.value, $0.key) })
        for marker in sourceMarkers {
            if let part = markerPart(marker, in: song), sourceNumbers[part.id] == nil { sourceNumbers[part.id] = marker.number }
        }
        let parents = Set(song.parts.compactMap(\.parentRegionID))
        for index in song.parts.indices {
            // Explicit empty arrays are essential: nil means all tracks in CatLive.
            song.parts[index].pitchTrackIDs = pitchTracks
            song.parts[index].pitchGroupIDs = pitchGroups
            if !parents.contains(song.parts[index].id), let key = sourceNumbers[song.parts[index].id] {
                song.parts[index].pitchSemitones = offsets[key] ?? 0
            }
            if song.parts[index].name.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("--") {
                let name = song.parts[index].name.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { song.parts[index].name = name }
            }
        }
        // Keep linked flags in sync with the cleaned drawer names.
        for index in song.markers?.indices ?? 0..<0 {
            if let source = song.markers?[index].sourceRegionID, let part = song.parts.first(where: { $0.id == source }) {
                song.markers?[index].name = part.name
            }
        }
        let loopRows = Self.rows((loopState["STATE_V2"] ?? "") + "\n" + (loopState["MS_STATE_V1"] ?? ""))
        var enabled: [String: [String]] = [:]
        for row in loopRows where row.count >= 6 && row[0] == "E" { enabled[Self.unescape(row[1])] = row }
        for index in song.parts.indices where !parents.contains(song.parts[index].id) {
            let region = song.parts[index]
            guard let key = sourceNumbers[region.id] else { continue }
            for slot in 1...4 {
                let points = sourceMarkers.map(\.marker).filter {
                    $0.name.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("*\(slot)") &&
                    $0.position >= region.startTime && $0.position <= region.endTime + 0.0005
                }.sorted { $0.position < $1.position }
                guard points.count >= 2, points[1].position > points[0].position + 0.0005 else {
                    if !points.isEmpty { warnings.insert("VS Hook: um par de multiloop incompleto foi mantido como marcador; revise os pontos *1 a *4.") }
                    continue
                }
                let anchors = points.prefix(2).compactMap { point in
                    let position = abs(point.position - region.endTime) <= 0.0005 ? region.endTime : point.position
                    return song.markers?.first { !$0.isTempo && abs($0.position - position) <= 0.000001 }?.id
                }
                guard anchors.count == 2, anchors[0] != anchors[1] else { continue }
                var loop = MultiLoop(name: "*\(slot)", marker1: anchors[0], marker2: anchors[1])
                let row = enabled[key] ?? []
                let loopField = [2, 3, 6, 7][slot - 1], mixerField = [4, 5, 8, 9][slot - 1]
                loop.enabled = row.indices.contains(loopField) && row[loopField] == "1"
                loop.mixerEnabled = row.indices.contains(mixerField) && row[mixerField] == "1"
                var rules: [UUID: MultiLoopTrack] = [:]
                for preset in loopRows where preset.count >= 6 && Self.unescape(preset[1]) == key && Int(preset[2]) == slot {
                    if preset[0] == "T", let fade = Double(preset[3]), fade.isFinite { loop.fadeSeconds = min(5, max(1, fade)); continue }
                    guard let id = trackIDs[Self.unescape(preset[3]).uppercased()] else { continue }
                    var rule = rules[id] ?? MultiLoopTrack(id: id, gain: 0)
                    switch preset[0] {
                    case "P":
                        rule.mute = preset[4] == "1"; rule.solo = preset[5] == "1"
                        if rule.mute { rule.solo = false; rule.autoFader = false }
                    case "F":
                        rule.autoFader = preset[4] == "1" || preset[5] == "1"
                        if rule.autoFader { rule.mute = false }
                    case "L":
                        if let db = Double(preset[4]), db.isFinite {
                            rule.gain = db <= -89.999 ? 0 : pow(10, min(12, db) / 20)
                            if db > 12 { warnings.insert("VS Hook: limites de Auto Fader acima de +12 dB foram ajustados ao máximo do CatLive.") }
                        }
                    default: continue
                    }
                    rules[id] = rule
                }
                loop.tracks = song.tracks.compactMap { rules[$0.id] }
                song.parts[index].multiLoops = (song.parts[index].multiLoops ?? []) + [loop]
            }
        }
        var setlist = project.regionSetlist ?? RegionSetlist()
        var listName: String?, entries: [[String]] = []
        func resolve(_ row: [String]) -> UUID? {
            let marker = row.count > 7 && (row[7] == "marker" || (row[7].isEmpty && row.count > 9 && row[9] == "1"))
            let key = marker && row.count > 10 && !row[10].isEmpty ? row[10] : row[2]
            let id: UUID?
            if marker { id = sourceMarkers.first { $0.number == key }.flatMap { markerPart($0, in: song)?.id } }
            else { id = regionIDs[key] }
            if let id, song.parts.contains(where: { $0.id == id }) { return id }
            // Saved bounds are only a fallback for older rows without an ID.
            guard key.isEmpty, let start = Double(row[3]), let end = Double(row[4]) else { return nil }
            return song.parts.first { abs($0.startTime - start) < 0.0005 && abs($0.endTime - end) < 0.0005 }?.id
        }
        func finishPlaylist() {
            guard let name = listName else { return }
            let playlistID = UUID()
            var ids: [UUID] = [], blocks: [(String, UInt32, Bool, Int)] = []
            for row in entries where row.count >= 6 {
                if row[1] == "block" || (Int(row[2]) ?? 0) < 0 {
                    let title = Self.unescape(row[5]).trimmingCharacters(in: .whitespacesAndNewlines)
                    blocks.append((title.isEmpty ? "Bloco" : title, Self.blockColor(row.count > 6 ? row[6] : "", number: Int(row[2]) ?? -1), row.count <= 13 || row[13] != "1", ids.count))
                } else if let id = resolve(row), let part = song.parts.first(where: { $0.id == id }) {
                    // Family children stay in their drawer; never duplicate the
                    // parent duration by adding its songs again at top level.
                    let root = part.parentRegionID ?? id
                    if !ids.contains(root) { ids.append(root) }
                } else { warnings.insert("VS Hook: músicas removidas do projeto de origem foram ignoradas nos repertórios.") }
            }
            setlist.playlists.append(RegionPlaylist(id: playlistID, name: name, songId: song.id, regionIds: ids))
            for block in blocks {
                setlist.blocks = (setlist.blocks ?? []) + [SetlistBlock(id: UUID(), songId: song.id, playlistId: playlistID, name: block.0,
                    color: block.1, beforeRegionId: ids.indices.contains(block.3) ? ids[block.3] : nil, symbol: block.2)]
            }
        }
        for row in Self.rows(playlistState["PLAYLISTS_DB_V3"] ?? "") {
            if row.first == "PLAYLIST" {
                finishPlaylist(); entries = []
                let name = row.count > 1 ? Self.unescape(row[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
                listName = name.isEmpty ? "Repertório \(setlist.playlists.count + 1)" : name
            } else if row.first == "END" { finishPlaylist(); listName = nil; entries = [] }
            else if row.first == "ITEM", listName != nil { entries.append(row) }
        }
        finishPlaylist()
        if !setlist.playlists.isEmpty {
            let selected = (playlistState["LAST_PLAYLIST_NAME_V1"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            setlist.selectedId = selected.isEmpty ? setlist.playlists.first?.id : setlist.playlists.first { $0.name == selected }?.id
            project.regionSetlist = setlist
        }
        project.songs[0] = song
    }

    private static func blockColor(_ key: String, number: Int) -> UInt32 {
        let palette: [UInt32] = [0xFFBD1F, 0x2EBD5C, 0x3385FF, 0x8F57F0, 0xFF6147, 0x1AB3C7, 0xF261B8, 0x94B32E]
        let names = ["yellow", "green", "blue", "purple", "red", "cyan", "pink", "olive"]
        if let index = names.firstIndex(of: key) { return palette[index] }
        if key == "orange" { return 0xF58F29 }
        if key == "white" || key == "none" { return 0x22262B }
        return palette[Int((number.magnitude > 0 ? number.magnitude - 1 : 0) % 8)]
    }
}
