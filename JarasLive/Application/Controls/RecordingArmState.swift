import Foundation

public extension Project {
    /// Recording templates use sequential mono hardware inputs with monitoring on.
    /// Arming remains session state and is applied only after creation succeeds.
    static func recordingMultitrack(name: String, channels: Int, trackPrefix: String = "Track") throws -> Project {
        guard (1...128).contains(channels) else { throw ProjectError.invalid("Choose between 1 and 128 channels.") }
        var project = Project.empty(name: name)
        project.songs[0].tracks = (1...channels).map { input in
            var track = Track(id: UUID(), name: trackPrefix + String(format: " %02d", input), role: .other, color: Track.defaultStandardColor)
            track.inputPatch = OutputPatch(firstChannel: input, channelCount: 1)
            track.recordingChannels = 1; track.inputMonitoring = true; track.outputs = [.master]
            return track
        }
        try project.validate()
        return project
    }
}

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
    public var hasConfiguredTracks: Bool { !modes.isEmpty }
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
