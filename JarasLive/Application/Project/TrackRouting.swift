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

/// Shared ancestry rules for folder audio, solo, pitch and mixer indentation.
public struct TrackHierarchy {
    private let parents: [UUID: UUID]
    private let children: [UUID: [UUID]]
    public init(_ tracks: [Track]) {
        parents = Dictionary(tracks.compactMap { track in track.parentTrackID.map { (track.id, $0) } }, uniquingKeysWith: { first, _ in first })
        children = Dictionary(grouping: tracks.filter { $0.parentTrackID != nil }, by: { $0.parentTrackID! }).mapValues { $0.map(\.id) }
    }
    public func ancestors(of id: UUID) -> [UUID] {
        var result: [UUID] = [], visited: Set<UUID> = [id], next = parents[id]
        while let parent = next, visited.insert(parent).inserted {
            result.append(parent); next = parents[parent]
        }
        return result
    }
    public func descendants(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [], pending = children[id] ?? []
        while let child = pending.popLast() {
            guard child != id, result.insert(child).inserted else { continue }
            pending.append(contentsOf: children[child] ?? [])
        }
        return result
    }
    public static func soloAudibleTracks(_ tracks: [Track]) -> Set<UUID>? {
        let solo = Set(tracks.filter(\.solo).map(\.id))
        guard !solo.isEmpty else { return nil }
        let hierarchy = TrackHierarchy(tracks)
        var audible = solo
        for id in solo {
            audible.formUnion(hierarchy.ancestors(of: id))
            audible.formUnion(hierarchy.descendants(of: id))
        }
        return audible
    }
}
public extension Song {
    var trackGroupDepths: [UUID: Int] {
        let hierarchy = TrackHierarchy(tracks)
        return Dictionary(tracks.map { ($0.id, hierarchy.ancestors(of: $0.id).count) }, uniquingKeysWith: { first, _ in first })
    }
}

public extension Song {
    /// Folder drops on another folder's member have two distinct directions.
    func isGroupMemberDrop(_ source: UUID, on target: UUID) -> Bool {
        tracks.contains { $0.parentTrackID == source } &&
        tracks.first { $0.id == target }?.parentTrackID != nil &&
        !TrackHierarchy(tracks).ancestors(of: source).contains(target)
    }
    /// Take the target and its following siblings, including each sibling's
    /// entire subtree. Never adopt an ancestor of the folder being moved.
    func groupAdoption(_ source: UUID, above target: UUID) -> (parent: UUID, roots: [UUID])? {
        guard isGroupMemberDrop(source, on: target),
              let index = tracks.firstIndex(where: { $0.id == target }),
              let parent = tracks[index].parentTrackID else { return nil }
        let hierarchy = TrackHierarchy(tracks)
        guard source != target, !hierarchy.ancestors(of: target).contains(source) else { return nil }
        let roots = tracks[index...].filter { $0.parentTrackID == parent && $0.id != source }.map(\.id)
        let ancestors = Set(hierarchy.ancestors(of: source))
        guard !roots.isEmpty, roots.allSatisfy({ !ancestors.contains($0) }) else { return nil }
        return (parent, roots)
    }
}

public struct NormalTrackDropDestination: Equatable {
    public let parent: UUID?
    public let before: UUID?
    public let indicatorTrack: UUID
    public let after: Bool
}

public extension Song {
    /// Resolve the visible boundary and membership together. In particular, the
    /// last child still belongs to its folder even when the following row does not.
    func normalTrackDropDestination(_ source: UUID, on target: UUID, after: Bool, outsideGroup: Bool = false) -> NormalTrackDropDestination? {
        guard source != target,
              tracks.contains(where: { $0.id == source && $0.kind == .standard }),
              !tracks.contains(where: { $0.parentTrackID == source }),
              let hit = tracks.first(where: { $0.id == target && $0.kind == .standard }) else { return nil }
        let remaining = tracks.filter { $0.id != source }
        let folder = tracks.contains { $0.parentTrackID == target }
        let parent = after && folder ? target : hit.parentTrackID
        if outsideGroup, let parent,
           let group = remaining.first(where: { $0.id == parent }) {
            let members = TrackHierarchy(remaining).descendants(of: parent).union([parent])
            guard let boundary = after ? remaining.lastIndex(where: { members.contains($0.id) }) : remaining.firstIndex(where: { $0.id == parent }) else { return nil }
            let insertion = boundary + (after ? 1 : 0)
            return NormalTrackDropDestination(parent: group.parentTrackID,
                before: insertion < remaining.count ? remaining[insertion].id : nil,
                indicatorTrack: remaining[boundary].id, after: after)
        }
        guard let index = remaining.firstIndex(where: { $0.id == target }) else { return nil }
        let insertion = index + (after ? 1 : 0)
        return NormalTrackDropDestination(parent: parent,
            before: insertion < remaining.count ? remaining[insertion].id : nil,
            indicatorTrack: target, after: after)
    }
}
