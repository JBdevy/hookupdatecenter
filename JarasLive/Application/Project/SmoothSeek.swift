import Foundation

public extension Song {
    func sectionRegion(at position: Double, includingEnd: Bool = false) -> Part? {
        parts.filter { position >= $0.startTime && (position < $0.endTime || (includingEnd && position == $0.endTime)) }
            .sorted {
                if ($0.parentRegionID != nil) != ($1.parentRegionID != nil) { return $0.parentRegionID != nil }
                if $0.startTime != $1.startTime { return $0.startTime > $1.startTime }
                return $0.endTime < $1.endTime
            }.first
    }
    func sectionMarkers(in region: Part) -> [TimelineMarker] {
        (markers ?? []).filter { $0.isSection && $0.position >= region.startTime && $0.position <= region.endTime }
            .sorted { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }
    }
}
public extension ShowController {
    @discardableResult func canCreateSectionMarker(at position: Double, includingEnd: Bool = false) -> Bool {
        guard current?.sectionRegion(at: position, includingEnd: includingEnd) != nil else {
            modalNotice = "Section markers can only be created inside a song."
            return false
        }
        return true
    }
}

/// Bounds the resizable section list while keeping the adjacent workspace visible.
public enum SmoothSeekPanelLayout {
    public static let columns = 6
    public static let height: Double = 180
    public static func visibleRows(for count: Int) -> Int { count <= 12 ? 2 : count <= 18 ? 3 : 4 }

    public static func sidebarWidth(available: Double, requested: Double, minimumPrimary: Double) -> Double {
        let available = available.isFinite ? max(0, available) : 0
        let maximum = max(0, available - min(max(0, minimumPrimary), available * 0.6))
        return min(maximum, max(min(100, maximum), requested.isFinite ? requested : available * 0.45))
    }
}

/// Progress is local to the current section, ending at the next section marker
/// (or the song end), never at an unrelated regular timeline marker.
public enum SectionPlaybackProgress {
    public static func fraction(position: Double, start: Double, end: Double) -> Double {
        guard position.isFinite, start.isFinite, end.isFinite, end > start else { return 0 }
        return min(1, max(0, (position - start) / (end - start)))
    }
}
