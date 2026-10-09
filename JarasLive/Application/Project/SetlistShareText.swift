import Foundation

/// A plain-text snapshot of the requested playlist, independent of selection or drawer state.
public enum SetlistShareText {
    /// `nil` requests All Regions. A playlist that no longer belongs to this song produces no text.
    public static func make(song: Song, setlist: RegionSetlist, playlistID: UUID?,
                            allRegionsTitle: String, totalDurationTitle: String) -> String {
        let title: String
        let regions: [Part]
        let roots = song.parts.filter { $0.parentRegionID == nil }
        if let playlistID {
            guard let playlist = setlist.playlists.first(where: { $0.id == playlistID && $0.songId == song.id }) else { return "" }
            title = playlist.name
            let lookup = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
            regions = playlist.regionIds.compactMap { lookup[$0] }
        } else {
            title = allRegionsTitle
            regions = roots.sorted { $0.startTime == $1.startTime ? $0.id.uuidString < $1.id.uuidString : $0.startTime < $1.startTime }
        }

        // Match the footer: each root contributes its full span once, with no drawer duplication.
        let total = regions.reduce(0.0) { sum, region in
            let seconds = region.endTime - region.startTime
            return sum + (seconds.isFinite ? max(0, seconds) : 0)
        }
        let seconds = Int(min(Double(Int.max / 2), total))
        let duration = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        let children = Dictionary(grouping: song.parts.filter { $0.parentRegionID != nil }, by: { $0.parentRegionID! })
        let blocks = Dictionary(grouping: (setlist.blocks ?? []).filter {
            $0.songId == song.id && $0.playlistId == playlistID
        }, by: \.beforeRegionId)
        var lines = [title, totalDurationTitle + ": " + duration, ""]
        func appendBlocks(before regionID: UUID?) {
            for block in blocks[regionID] ?? [] where !block.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if lines.last != "" { lines.append("") }
                lines.append(block.name)
            }
        }
        for (index, region) in regions.enumerated() {
            appendBlocks(before: region.id)
            lines.append(String(format: "%02d", index + 1) + ". " + region.displayName)
            let drawer = (children[region.id] ?? []).sorted {
                $0.startTime == $1.startTime ? $0.endTime < $1.endTime : $0.startTime < $1.startTime
            }
            lines += drawer.enumerated().map { offset, child in
                "    " + (offset == drawer.count - 1 ? "└─ " : "├─ ") + child.displayName
            }
        }
        appendBlocks(before: nil)
        if lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
