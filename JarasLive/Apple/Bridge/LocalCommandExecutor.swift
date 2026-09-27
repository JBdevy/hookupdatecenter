import Foundation
@MainActor final class LocalCommandExecutor: CommandExecutor {
    private let core = JarasCoreBridge()
    func addTrack(id: UUID, name: String, role: TrackRole) throws { try core.addTrack(id: id.uuidString, name: name, role: role.rawValue) }
    func load(_ project: Project) throws { try project.validate(); try core.load(projectData: JSONEncoder().encode(project)) }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws { try core.execute(command: command.rawValue, target: target?.uuidString, value: value) }
    func snapshot() throws -> ShowSnapshot { try JSONDecoder().decode(ShowSnapshot.self, from: core.snapshot()) }
    func playbackSnapshot() throws -> PlaybackSnapshot { try JSONDecoder().decode(PlaybackSnapshot.self, from: core.playbackSnapshot()) }
    func advance(_ elapsed: Double) { core.advance(elapsed) }
    func finishCurrentSong(_ enabled: Bool) { core.finishCurrentSong(enabled) }
}
