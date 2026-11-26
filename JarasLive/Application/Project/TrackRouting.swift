import Foundation
import Combine

public enum TrackVisibilityArea: String, CaseIterable, Sendable {
    case trackMixer, barMixer
}

/// Local presentation only. Hiding a folder derives its descendants each time,
/// so showing it again restores each child's independent visibility choice.
public struct TrackVisibilityState: Equatable, Sendable {
    public var trackMixer: Set<UUID> = []
    public var barMixer: Set<UUID> = []
    public init(trackMixer: Set<UUID> = [], barMixer: Set<UUID> = []) {
        self.trackMixer = trackMixer; self.barMixer = barMixer
    }
    public func hidden(in area: TrackVisibilityArea) -> Set<UUID> {
        area == .trackMixer ? trackMixer : barMixer
    }
    public mutating func setVisible(_ visible: Bool, track: UUID, in area: TrackVisibilityArea) {
        if area == .trackMixer {
            if visible { trackMixer.remove(track) } else { trackMixer.insert(track) }
        } else {
            if visible { barMixer.remove(track) } else { barMixer.insert(track) }
        }
    }
    public func effectiveHidden(in tracks: [Track], area: TrackVisibilityArea) -> Set<UUID> {
        let selected = hidden(in: area)
        guard !selected.isEmpty else { return [] }
        let hierarchy = TrackHierarchy(tracks)
        return tracks.reduce(into: selected) { result, track in
            if hierarchy.ancestors(of: track.id).contains(where: selected.contains) { result.insert(track.id) }
        }
    }
    public func visibleTracks(in tracks: [Track], area: TrackVisibilityArea) -> [Track] {
        let hidden = effectiveHidden(in: tracks, area: area)
        guard !hidden.isEmpty else { return tracks }
        return tracks.filter { !hidden.contains($0.id) }
    }
}

@MainActor public final class TrackVisibilityPreferences: ObservableObject {
    public static let shared = TrackVisibilityPreferences()
    @Published public private(set) var revision: UInt64 = 0
    private let defaults: UserDefaults
    private var cached: [UUID: TrackVisibilityState] = [:]
    public init(defaults: UserDefaults = UserDefaults(suiteName: "com.hookdeveloper.catlive.track-visibility")!) {
        self.defaults = defaults
    }
    private func key(_ project: UUID, _ area: TrackVisibilityArea) -> String {
        "trackVisibility.\(project.uuidString).\(area.rawValue)"
    }
    public func state(for project: UUID) -> TrackVisibilityState {
        if let state = cached[project] { return state }
        func read(_ area: TrackVisibilityArea) -> Set<UUID> {
            Set((defaults.stringArray(forKey: key(project, area)) ?? []).compactMap(UUID.init(uuidString:)))
        }
        let state = TrackVisibilityState(trackMixer: read(.trackMixer), barMixer: read(.barMixer))
        cached[project] = state
        return state
    }
    public func setVisible(_ visible: Bool, track: UUID, in area: TrackVisibilityArea, project: UUID) {
        var state = state(for: project)
        let previous = state
        state.setVisible(visible, track: track, in: area)
        guard state != previous else { return }
        cached[project] = state
        defaults.set(state.hidden(in: area).map(\.uuidString).sorted(), forKey: key(project, area))
        revision &+= 1
    }
}

public enum TrackSendTap: String, Codable, CaseIterable, Sendable {
    case preFX, postFX, preFader, postFader
    public var isPreFader: Bool { self != .postFader }
    public var title: String {
        switch self {
        case .preFX: return "Pre-FX"
        case .postFX: return "Post-FX"
        case .preFader: return "Pre-Fader"
        case .postFader: return "Post-Fader"
        }
    }
}

public struct TrackRouting: Codable, Equatable, Sendable {
    public var receives: [UUID?] = []
    public var transmitters: [UUID?] = []
    public var mainReceiveSlot: Int?
    public var mainSendOrder: Int?
    public var sendTaps: [String: TrackSendTap]?
    public var sendGains: [String: Double]?
    public init(receives: [UUID?] = [], transmitters: [UUID?] = [], mainReceiveSlot: Int? = nil) {
        self.receives = receives; self.transmitters = transmitters
        self.mainReceiveSlot = mainReceiveSlot
    }
    public func sendTap(to destination: UUID) -> TrackSendTap {
        sendTaps?[destination.uuidString] ?? sendTaps?[destination.uuidString.lowercased()] ?? .postFader
    }
    public mutating func setSendTap(_ tap: TrackSendTap, to destination: UUID) {
        var taps = sendTaps ?? [:]
        taps[destination.uuidString.lowercased()] = nil
        taps[destination.uuidString] = tap == .postFader ? nil : tap
        sendTaps = taps.isEmpty ? nil : taps
    }
    public func sendGain(to destination: UUID) -> Double {
        let gain = sendGains?[destination.uuidString] ?? sendGains?[destination.uuidString.lowercased()] ?? 1
        return gain.isFinite ? min(1, max(0, gain)) : 1
    }
    public mutating func setSendGain(_ gain: Double, to destination: UUID) {
        guard gain.isFinite else { return }
        let value = min(1, max(0, gain))
        var gains = sendGains ?? [:]
        gains[destination.uuidString.lowercased()] = nil
        gains[destination.uuidString] = value == 1 ? nil : value
        sendGains = gains.isEmpty ? nil : gains
    }
    mutating func removeUnusedSendSettings() {
        let destinations = Set(transmitters.compactMap { $0?.uuidString })
        let taps = sendTaps?.filter { destinations.contains($0.key.uppercased()) }
        let gains = sendGains?.filter { destinations.contains($0.key.uppercased()) }
        sendTaps = taps?.isEmpty == false ? taps : nil
        sendGains = gains?.isEmpty == false ? gains : nil
    }
}
public struct TrackConnection: Hashable, Sendable {
    public let source: UUID
    public let destination: UUID
}

public enum HozMixerTrackScope: String, CaseIterable {
    case all, tracks, groups
    public var label: String {
        switch self {
        case .all: return "Hoz Mixer All"
        case .tracks: return "Tracks"
        case .groups: return "Groups"
        }
    }
}

public enum HozMixerSignal: String, CaseIterable {
    case audio = "Audio", midi = "MIDI", sends = "Sends", bus = "Bus"
}

public extension Song {
    var hozMixerBusSources: [UUID: [UUID]] {
        let order = Dictionary(tracks.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let routes = trackConnections.filter { order[$0.source] != nil && order[$0.destination] != nil }
        return Dictionary(grouping: routes, by: \.destination).mapValues {
            $0.map(\.source).sorted { order[$0, default: 0] < order[$1, default: 0] }
        }
    }

    func hozMixerTracks(_ candidates: [Track], scope: HozMixerTrackScope, signals: Set<HozMixerSignal>) -> [Track] {
        guard scope != .all || !signals.isEmpty else { return candidates }
        let groups = Set(tracks.compactMap(\.parentTrackID))
        let connections = signals.contains(.sends) || signals.contains(.bus) ? trackConnections : []
        let senders = Set(connections.map(\.source))
        let receivers = Set(connections.map(\.destination))
        return candidates.filter { track in
            let isGroup = groups.contains(track.id)
            guard scope == .all || (scope == .groups) == isGroup else { return false }
            return signals.isEmpty
                || (signals.contains(.audio) && (track.inputPatch?.firstChannel ?? 0) > 0)
                || (signals.contains(.midi) && (track.midiInput ?? 0) > 0)
                || (signals.contains(.sends) && senders.contains(track.id))
                || (signals.contains(.bus) && (receivers.contains(track.id) || track.receivesMain))
        }
    }
}

public extension Song {
    /// Receive and Transmitter describe the same connection from opposite ends.
    /// A set avoids doubling the signal when both ends name each other.
    var trackConnections: Set<TrackConnection> {
        var result: Set<TrackConnection> = []
        // Routing is checked before duplicate IDs are rejected by Project.validate.
        // Preserve the original first-match semantics without trapping on a bad file.
        let tracksByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for track in tracks {
            for destination in track.routing?.transmitters.compactMap({ $0 }) ?? [] { result.insert(TrackConnection(source: track.id, destination: destination)) }
            for source in track.routing?.receives.compactMap({ $0 }) ?? [] { result.insert(TrackConnection(source: source, destination: track.id)) }
        }
        return result.filter { edge in
            guard let source = tracksByID[edge.source] else { return true }
            return source.parentTrackID != edge.destination || !source.outputPatches.contains(.masterGroup)
        }
    }
    /// Reconcile edits from either end without doubling the audible connection.
    mutating func applyReciprocalRouting(_ edits: [UUID: TrackRouting]) -> [UUID: TrackRouting] {
        let before = tracks
        let indices = Dictionary(tracks.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        for (id, routing) in edits { if let i = indices[id] { tracks[i].routing = routing } }
        for (id, routing) in edits {
            guard let index = indices[id] else { continue }
            let previous = before[index].routing ?? TrackRouting()
            for receive in [true, false] {
                let old = Set((receive ? previous.receives : previous.transmitters).compactMap { $0 })
                let new = Set((receive ? routing.receives : routing.transmitters).compactMap { $0 })
                for other in old.union(new) where other != id {
                    guard let i = indices[other] else { continue }
                    var mirror = tracks[i].routing ?? TrackRouting()
                    var slots = receive ? mirror.transmitters : mirror.receives
                    if new.contains(other) {
                        if !slots.contains(id) {
                            let empty = slots.indices.first { slots[$0] == nil && (receive || $0 != mirror.mainReceiveSlot) }
                            if let empty { slots[empty] = id } else { slots.append(id) }
                        }
                    } else { slots = slots.map { $0 == id ? nil : $0 } }
                    if receive { mirror.transmitters = slots } else { mirror.receives = slots }
                    tracks[i].routing = mirror
                }
            }
        }
        for index in tracks.indices { tracks[index].routing?.removeUnusedSendSettings() }
        var result: [UUID: TrackRouting] = [:]
        for (old, current) in zip(before, tracks) where old.routing != current.routing { result[current.id] = current.routing ?? TrackRouting() }
        return result
    }
    func validateTrackRouting() throws {
        let audio = Set(tracks.filter { $0.kind == .standard }.map(\.id))
        var edges = trackConnections
        for track in tracks {
            if track.routing != nil {
                guard track.kind == .standard else { throw ProjectError.invalid("Invalid track routing") }
            }
            if let routing = track.routing, let slot = routing.mainReceiveSlot {
                guard routing.receives.indices.contains(slot), routing.receives[slot] == nil, track.role.rawValue != "vinhetas" else {
                    throw ProjectError.invalid("Invalid track routing")
                }
            }
            if let parent = track.parentTrackID, track.outputPatches.contains(.masterGroup) {
                edges.insert(TrackConnection(source: track.id, destination: parent))
            }
        }
        var adjacency: [UUID: Set<UUID>] = [:]
        var incoming: [UUID: Int] = [:]
        for edge in edges {
            guard edge.source != edge.destination, audio.contains(edge.source), audio.contains(edge.destination) else { throw ProjectError.invalid("Invalid track routing") }
            adjacency[edge.source, default: []].insert(edge.destination)
            incoming[edge.destination, default: 0] += 1
        }
        // Iterative topological traversal also detects disconnected cycles, but
        // does not consume one stack frame per track in a long routing chain.
        var pending = audio.filter { incoming[$0, default: 0] == 0 }.map { $0 }
        var visited = 0
        while let id = pending.popLast() {
            visited += 1
            for next in adjacency[id] ?? [] {
                incoming[next, default: 0] -= 1
                if incoming[next] == 0 { pending.append(next) }
            }
        }
        guard visited == audio.count else { throw ProjectError.invalid("This routing would create an audio feedback loop.") }
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
    /// A selected folder targets itself; a selected member targets its immediate
    /// folder. Resolve before editing so dissolving a parent cannot retarget a child.
    func groupsForTrackSelection(_ selection: Set<UUID>) -> [UUID] {
        let folders = Set(tracks.compactMap(\.parentTrackID))
        let groups = Set(tracks.filter { selection.contains($0.id) }.compactMap { track in
            folders.contains(track.id) ? track.id : track.parentTrackID
        })
        return tracks.filter { groups.contains($0.id) }.map(\.id)
    }
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

public extension Song {
    func trackDragRoots(_ selection: Set<UUID>) -> [UUID] {
        let hierarchy = TrackHierarchy(tracks)
        return tracks.filter { $0.kind == .standard && selection.contains($0.id) &&
            selection.isDisjoint(with: hierarchy.ancestors(of: $0.id)) }.map(\.id)
    }
}
