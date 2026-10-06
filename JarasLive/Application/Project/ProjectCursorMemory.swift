import Foundation

/// Local workspace state: moving a cursor never rewrites the audio project.
@MainActor public final class ProjectCursorMemory {
    private let preferences: UserDefaults
    private var cached: [UUID: SavedProjectCursor] = [:]
    public init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    private func key(_ project: UUID) -> String { "jaras.projectCursor." + project.uuidString }
    public func cursor(for project: UUID) -> SavedProjectCursor? {
        if let saved = cached[project] { return saved }
        guard let value = preferences.dictionary(forKey: key(project)),
              let song = value["song"] as? String, let songID = UUID(uuidString: song),
              let position = value["position"] as? Double, position.isFinite, position >= 0 else { return nil }
        let saved = SavedProjectCursor(songID: songID, position: position)
        cached[project] = saved
        return saved
    }
    public func remember(project: UUID, songID: UUID?, position: Double) {
        guard let songID, position.isFinite, position >= 0 else { return }
        let saved = SavedProjectCursor(songID: songID, position: position)
        guard cached[project] != saved else { return }
        cached[project] = saved
        preferences.set(["song": songID.uuidString, "position": position], forKey: key(project))
    }
}
