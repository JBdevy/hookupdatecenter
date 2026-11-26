import Foundation

/// The matrix edits the existing Patch schema, including connections described
/// from the receive side. No second routing graph is stored in the project.
public enum MatrixPatchDestination: Equatable, Hashable {
    case output(OutputPatch)
    case track(UUID)
}

public extension Song {
    func matrixConnection(source: UUID, destination: UUID) -> Bool {
        guard let from = tracks.first(where: { $0.id == source }),
              let to = tracks.first(where: { $0.id == destination }) else { return false }
        return (from.parentTrackID == destination && from.outputPatches.contains(.masterGroup)) ||
            from.routing?.transmitters.contains(destination) == true ||
            to.routing?.receives.contains(source) == true
    }

    /// One reversible edit, removing every representation of a connection.
    /// Validate the candidate before committing, so feedback never enters audio.
    mutating func toggleMatrixConnection(source: UUID, destination: UUID) throws {
        var candidate = self
        try candidate.setMatrixConnection(source: source, destination: destination,
                                          enabled: !matrixConnection(source: source, destination: destination))
        try candidate.validateTrackRouting()
        self = candidate
    }

    /// Edit a candidate song. The caller validates the whole stroke before publishing it.
    mutating func setMatrixConnection(source: UUID, destination: UUID, enabled: Bool) throws {
        guard source != destination,
              let from = tracks.firstIndex(where: { $0.id == source && $0.kind == .standard }),
              let to = tracks.firstIndex(where: { $0.id == destination && $0.kind == .standard }) else {
            throw ProjectError.invalid("Invalid track routing")
        }
        guard matrixConnection(source: source, destination: destination) != enabled else { return }
        if !enabled {
            tracks[from].routing?.transmitters.removeAll { $0 == destination }
            if var routing = tracks[to].routing {
                // Preserve slot positions, including a Main capture.
                if routing.mainReceiveSlot != nil { routing.receives = routing.receives.map { $0 == source ? nil : $0 } }
                else { routing.receives.removeAll { $0 == source } }
                tracks[to].routing = routing
            }
            if tracks[from].parentTrackID == destination {
                tracks[from].outputs = tracks[from].outputPatches.filter { $0 != .masterGroup }
                tracks[from].patch = nil; tracks[from].secondaryPatch = nil
            }
        } else if tracks[from].parentTrackID == destination {
            tracks[from].outputs = tracks[from].outputPatches.filter { $0 != .none } + [.masterGroup]
            tracks[from].patch = nil; tracks[from].secondaryPatch = nil
        } else {
            var routes = tracks[from].routing ?? TrackRouting()
            routes.transmitters.append(destination)
            tracks[from].routing = routes
        }
    }
}
