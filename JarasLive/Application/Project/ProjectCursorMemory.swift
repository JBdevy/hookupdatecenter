import Foundation

/// Local workspace state: moving a cursor never rewrites the audio project.
@MainActor public final class ProjectCursorMemory {
    private let preferences: UserDefaults?
    // Cursor navigation is not an application preference. Writing standard
    // defaults here synchronously notifies every SwiftUI AppStorage observer.
    // Keep its small local store separate and persist off the interaction path.
    private static let domain = "com.hookdeveloper.catlive.project-cursors"
    private static let persistence = DispatchQueue(label: "CatLive cursor persistence", qos: .utility)
    private static var session: [UUID: SavedProjectCursor] = [:]
    private var cached: [UUID: SavedProjectCursor] = [:]
    public init(preferences: UserDefaults? = nil) { self.preferences = preferences }
    private func key(_ project: UUID) -> String { "jaras.projectCursor." + project.uuidString }
    public func cursor(for project: UUID) -> SavedProjectCursor? {
        if let saved = cached[project] { return saved }
        if preferences == nil, let saved = Self.session[project] { cached[project] = saved; return saved }
        let stored = preferences?.dictionary(forKey: key(project)) ?? (preferences == nil
            ? CFPreferencesCopyAppValue(key(project) as CFString, Self.domain as CFString) as? [String: Any]
            : nil)
        // Existing installations retain their last local position without
        // rewriting the standard defaults domain during navigation.
        guard let value = stored ?? (preferences == nil ? UserDefaults.standard.dictionary(forKey: key(project)) : nil),
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
        let value: [String: Any] = ["song": songID.uuidString, "position": position]
        if let preferences { preferences.set(value, forKey: key(project)); return }
        Self.session[project] = saved
        let key = key(project), domain = Self.domain
        Self.persistence.async {
            CFPreferencesSetAppValue(key as CFString, value as CFPropertyList, domain as CFString)
            CFPreferencesAppSynchronize(domain as CFString)
        }
    }
    static func flushPendingWrites() async {
        await withCheckedContinuation { continuation in
            persistence.async { continuation.resume() }
        }
    }
}
