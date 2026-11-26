import Foundation
import Combine
/// Mixer selections remain observable while the export configuration is open.
@MainActor final class AudioExportSelection: ObservableObject {
    static let shared = AudioExportSelection()
    @Published private var trackSelections: [UUID:Set<UUID>] = [:]
    private var clipSelections: [UUID:Set<UUID>] = [:]
    private var regionSelections: [UUID:Set<UUID>] = [:]
    /// Selections belong to an open session, not to UUIDs preserved in a copy
    /// or backup of the project. Call after committing a new session.
    func clear() {
        trackSelections.removeAll()
        clipSelections.removeAll()
        regionSelections.removeAll()
    }
    func setTracks(_ ids: Set<UUID>, song: UUID?) {
        guard let song, tracks(song) != ids else { return }
        trackSelections[song] = ids
    }
    func setClips(_ ids: Set<UUID>, song: UUID?) { if let song { clipSelections[song] = ids } }
    func setRegions(_ ids: Set<UUID>, song: UUID?) { if let song { regionSelections[song] = ids } }
    func tracks(_ song: UUID) -> Set<UUID> { trackSelections[song] ?? [] }
    func clips(_ song: UUID) -> Set<UUID> { clipSelections[song] ?? [] }
    func regions(_ song: UUID) -> Set<UUID> { regionSelections[song] ?? [] }
}
