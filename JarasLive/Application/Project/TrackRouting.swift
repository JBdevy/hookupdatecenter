import Foundation

public struct TrackRouting: Codable, Equatable, Sendable {
    public var receives: [UUID?] = []
    public var transmitters: [UUID?] = []
    public init(receives: [UUID?] = [], transmitters: [UUID?] = []) {
        self.receives = receives; self.transmitters = transmitters
    }
}
public struct TrackConnection: Hashable, Sendable {
    public let source: UUID
    public let destination: UUID
}
public extension Song {
    /// Receive and Transmitter describe the same connection from opposite ends.
    /// A set avoids doubling the signal when both ends name each other.
    var trackConnections: Set<TrackConnection> {
        var result: Set<TrackConnection> = []
        for track in tracks {
            for destination in track.routing?.transmitters.compactMap({ $0 }) ?? [] { result.insert(TrackConnection(source: track.id, destination: destination)) }
            for source in track.routing?.receives.compactMap({ $0 }) ?? [] { result.insert(TrackConnection(source: source, destination: track.id)) }
        }
        return result.filter { edge in
            guard let source = tracks.first(where: { $0.id == edge.source }) else { return true }
            return source.parentTrackID != edge.destination || !source.outputPatches.contains(.masterGroup)
        }
    }
    func validateTrackRouting() throws {
        let audio = Set(tracks.filter { $0.kind == .standard }.map(\.id))
        var edges = trackConnections
        for track in tracks {
            if track.routing != nil {
                guard track.kind == .standard else { throw ProjectError.invalid("Invalid track routing") }
            }
            if let parent = track.parentTrackID, track.outputPatches.contains(.masterGroup) {
                edges.insert(TrackConnection(source: track.id, destination: parent))
            }
        }
        var adjacency: [UUID: Set<UUID>] = [:]
        for edge in edges {
            guard edge.source != edge.destination, audio.contains(edge.source), audio.contains(edge.destination) else { throw ProjectError.invalid("Invalid track routing") }
            adjacency[edge.source, default: []].insert(edge.destination)
        }
        var visiting: Set<UUID> = [], finished: Set<UUID> = []
        func visit(_ id: UUID) throws {
            if finished.contains(id) { return }
            guard visiting.insert(id).inserted else { throw ProjectError.invalid("This routing would create an audio feedback loop.") }
            for next in adjacency[id] ?? [] { try visit(next) }
            visiting.remove(id); finished.insert(id)
        }
        for id in audio { try visit(id) }
    }
}
