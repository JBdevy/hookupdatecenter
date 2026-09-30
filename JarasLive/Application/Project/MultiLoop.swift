import Foundation

public struct MultiLoopTrack: Codable, Equatable, Identifiable, Sendable {
    // A stable sentinel denotes the master; real tracks retain their UUIDs.
    public static let masterID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    public var id: UUID
    public var gain: Double = 1
    public var autoFader = false
    public var mute = false
    public var solo = false
    public init(id: UUID, gain: Double = 1) { self.id = id; self.gain = gain }
}
public struct MultiLoop: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var marker1: UUID
    public var marker2: UUID
    public var fadeSeconds: Double = 3
    public var tracks: [MultiLoopTrack] = []
    public init(name: String, marker1: UUID, marker2: UUID) {
        self.name = name; self.marker1 = marker1; self.marker2 = marker2
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              marker1 != marker2, fadeSeconds.isFinite, (1...5).contains(fadeSeconds),
              Set(tracks.map(\.id)).count == tracks.count,
              tracks.allSatisfy({ $0.gain.isFinite && $0.gain >= 0 && $0.gain <= pow(10, 12.0 / 20) }) else {
            throw ProjectError.invalid("Invalid multiloop")
        }
    }
}
public struct MultiLoopPlayback: Codable, Equatable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var amount: Double
    public var gates: Bool
    public var released: Bool
    public var tracks: [MultiLoopTrack]
}
public extension Song {
    func multiLoopMarkers(in region: Part) -> [TimelineMarker] {
        (markers ?? []).filter { !$0.isTempo && $0.sourceRegionID == nil && $0.unifiedRegionID == nil && $0.position >= region.startTime && $0.position <= region.endTime }
            .sorted { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }
    }
}

public extension MultiLoopPlayback {
    func gain(_ original: Double, rule: MultiLoopTrack?) -> Double {
        guard let rule, rule.autoFader else { return original }
        return original + (min(original, rule.gain) - original) * min(1, max(0, amount))
    }
    func projectionSong(_ song: Song) -> Song {
        guard gates else { return song }
        let rules = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let hasSolo = tracks.contains { $0.solo && $0.id != MultiLoopTrack.masterID }
        var result = song
        for i in result.tracks.indices where result.tracks[i].kind != .standard {
            let rule = rules[result.tracks[i].id]
            result.tracks[i].mute = result.tracks[i].mute || rule?.mute == true || (hasSolo && rule?.solo != true)
            result.tracks[i].volume = gain(result.tracks[i].volume, rule: rule)
        }
        return result
    }
}
