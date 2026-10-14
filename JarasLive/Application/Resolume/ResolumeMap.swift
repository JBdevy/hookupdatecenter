import Foundation

public struct ResolumeCue: Equatable, Sendable {
    public var key: String
    public var song: UUID
    public var region: UUID
    public var start: Double
    public var end: Double
    public var position: Double
    public var name: String
    public var deckName: String
    public var deck: Int
    public var column: Int
    public var isRegion: Bool { column == 1 }
}
public struct ResolumeMap: Equatable, Sendable {
    public var assignments: [String: String]
    public var cues: [ResolumeCue]
    public static func assignment(_ text: String) -> (deck: Int, column: Int)? { ResolumeSettings.assignment(text) }
    /// Same zero-based persisted assignments as VS Hook; OSC indices are one-based.
    /// Existing sources never get renumbered when regions move on the timeline.
    public static func build(project: Project, settings: ResolumeSettings, createMissing: Bool = true) -> Self {
        let saved = settings.includeMarkers ? settings.withMarkers : settings.regionsOnly
        var sources: [ResolumeCue] = []
        for song in project.songs {
            let parents = Set(song.parts.compactMap(\.parentRegionID))
            let regions = song.parts.filter { !parents.contains($0.id) }.sorted {
                $0.startTime == $1.startTime ? $0.id.uuidString < $1.id.uuidString : $0.startTime < $1.startTime
            }
            for region in regions {
                sources.append(ResolumeCue(key: "region:\(region.id.uuidString)", song: song.id, region: region.id,
                    start: region.startTime, end: region.endTime, position: region.startTime,
                    name: "Start", deckName: region.name, deck: 0, column: 1))
            }
            if settings.includeMarkers {
                for marker in song.markers ?? [] where !marker.isTempo && marker.sourceRegionID == nil {
                    guard let region = regions.filter({ marker.position > $0.startTime + 0.0005 && marker.position < $0.endTime - 0.0005 })
                        .min(by: { $0.endTime - $0.startTime < $1.endTime - $1.startTime }) else { continue }
                    sources.append(ResolumeCue(key: "marker:\(marker.id.uuidString)", song: song.id, region: region.id,
                        start: region.startTime, end: region.endTime, position: marker.position,
                        name: marker.name, deckName: region.name, deck: 0, column: 0))
                }
            }
        }
        var result: [String: String] = [:], decks = Set<Int>()
        let regions = sources.filter(\.isRegion)
        for source in regions.sorted(by: { (saved[$0.key].flatMap(assignment)?.deck ?? Int.max) < (saved[$1.key].flatMap(assignment)?.deck ?? Int.max) }) {
            if let a = saved[source.key].flatMap(assignment), a.column == 0, decks.insert(a.deck).inserted { result[source.key] = "\(a.deck):0" }
        }
        var next = (decks.max() ?? -1) + 1
        if createMissing {
            for region in regions where result[region.key] == nil { result[region.key] = "\(next):0"; next += 1 }
        }
        for region in regions {
            guard let deck = result[region.key].flatMap(assignment)?.deck else { continue }
            let markers = sources.filter { !$0.isRegion && $0.region == region.region }.sorted {
                $0.position == $1.position ? $0.key < $1.key : $0.position < $1.position
            }
            var columns: Set<Int> = [0]
            for marker in markers {
                if let a = saved[marker.key].flatMap(assignment), a.deck == deck, a.column > 0, columns.insert(a.column).inserted { result[marker.key] = "\(deck):\(a.column)" }
            }
            var column = (columns.max() ?? 0) + 1
            if createMissing {
                for marker in markers where result[marker.key] == nil { result[marker.key] = "\(deck):\(column)"; column += 1 }
            }
        }
        let cues = sources.compactMap { source -> ResolumeCue? in
            guard let a = result[source.key].flatMap(assignment) else { return nil }
            var cue = source; cue.deck = a.deck + 1; cue.column = a.column + 1; return cue
        }.sorted { $0.position == $1.position ? ($0.deck, $0.column) < ($1.deck, $1.column) : $0.position < $1.position }
        return Self(assignments: result, cues: cues)
    }
    public func cue(song: UUID?, at position: Double) -> ResolumeCue? {
        cues.last { $0.song == song && $0.position <= position + 0.000001 && position >= $0.start - 0.0005 && position < $0.end - 0.0005 }
    }
}

/// Stateful cue selection is independent of networking, enabling transport regression tests.
public struct ResolumeFollower {
    private var previous: Double?
    private var clock: Double?
    private var running = false
    private var selected: ResolumeCue?
    public init() {}
    public struct Action: Equatable {
        public var cue: ResolumeCue?
        public var speed: Float?
    }
    public mutating func update(map: ResolumeMap, song: UUID?, position: Double, playing: Bool, time: Double) -> Action {
        let cue = map.cue(song: song, at: position)
        let jump = previous.map { position < $0 - 0.08 || position > $0 + max(0.35, time - (clock ?? time) + 0.25) } ?? true
        let changed = cue != selected
        let trigger = changed || (playing && running && jump)
        let action = Action(cue: trigger ? cue : nil, speed: clock == nil || playing != running ? (playing ? 1 : 0) : nil)
        selected = cue; previous = position; clock = time; running = playing
        return action
    }
}
