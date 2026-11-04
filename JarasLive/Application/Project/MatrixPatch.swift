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
        guard source != destination,
              let from = tracks.firstIndex(where: { $0.id == source && $0.kind == .standard }),
              let to = tracks.firstIndex(where: { $0.id == destination && $0.kind == .standard }) else {
            throw ProjectError.invalid("Invalid track routing")
        }
        var candidate = self
        if matrixConnection(source: source, destination: destination) {
            candidate.tracks[from].routing?.transmitters.removeAll { $0 == destination }
            candidate.tracks[to].routing?.receives.removeAll { $0 == source }
            if tracks[from].parentTrackID == destination {
                candidate.tracks[from].outputs = tracks[from].outputPatches.filter { $0 != .masterGroup }
                candidate.tracks[from].patch = nil; candidate.tracks[from].secondaryPatch = nil
            }
        } else if tracks[from].parentTrackID == destination {
            candidate.tracks[from].outputs = tracks[from].outputPatches.filter { $0 != .none } + [.masterGroup]
            candidate.tracks[from].patch = nil; candidate.tracks[from].secondaryPatch = nil
        } else {
            var routes = tracks[from].routing ?? TrackRouting()
            routes.transmitters.append(destination)
            candidate.tracks[from].routing = routes
        }
        try candidate.validateTrackRouting()
        self = candidate
    }
}
