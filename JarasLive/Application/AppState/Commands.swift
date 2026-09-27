import Foundation
public enum ShowCommand: String, Sendable { case play, stop, next, previous, queue, select, toggleLoop, seek, subPlay, subStop, subSeek, stopAll, volume, pan, mute, solo }
@MainActor public protocol CommandExecutor {
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws
    func addTrack(id: UUID, name: String, role: TrackRole) throws
    func load(_ project: Project) throws
    func snapshot() throws -> ShowSnapshot
    func playbackSnapshot() throws -> PlaybackSnapshot
    func advance(_ elapsed: Double)
    func finishCurrentSong(_ enabled: Bool)
}
@MainActor public final class RemoteCommandExecutor: CommandExecutor {
    public init() {}
    public func execute(_ command: ShowCommand, target: UUID?, value: Double) throws { throw BackendFailure.notConfigured }
    public func addTrack(id: UUID, name: String, role: TrackRole) throws { throw BackendFailure.notConfigured }
    public func load(_ project: Project) throws { throw BackendFailure.notConfigured }
    public func snapshot() throws -> ShowSnapshot { throw BackendFailure.notConfigured }
    public func playbackSnapshot() throws -> PlaybackSnapshot { throw BackendFailure.notConfigured }
    public func advance(_ elapsed: Double) {}
    public func finishCurrentSong(_ enabled: Bool) {}
}
