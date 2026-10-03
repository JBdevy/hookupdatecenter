import Foundation

/// Session arming intent is independent of the current selection and input permission.
public struct RecordingArmState: Equatable {
    public enum Mode: String, Equatable {
        case off, manual, automatic
        public var next: Self {
            switch self { case .off: return .manual; case .manual: return .automatic; case .automatic: return .off }
        }
    }
    private var modes: [UUID: Mode] = [:]
    public private(set) var selected: Set<UUID> = []
    public init() {}
    public func mode(for track: UUID) -> Mode { modes[track] ?? .off }
    public var armed: Set<UUID> {
        Set(modes.compactMap { id, mode in mode == .manual || (mode == .automatic && selected.contains(id)) ? id : nil })
    }
    public mutating func set(_ mode: Mode, tracks: Set<UUID>) {
        for id in tracks { modes[id] = mode == .off ? nil : mode }
    }
    public mutating func select(_ tracks: Set<UUID>) { selected = tracks }
    public mutating func retain(_ tracks: Set<UUID>) {
        modes = modes.filter { tracks.contains($0.key) }
        selected.formIntersection(tracks)
    }
}
