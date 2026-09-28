import Foundation
/// Shared selection snapshot; export reads it only when its configuration opens.
@MainActor final class AudioExportSelection {
    static let shared = AudioExportSelection()
    private var trackSelections: [UUID:Set<UUID>] = [:]
    private var clipSelections: [UUID:Set<UUID>] = [:]
    private var regionSelections: [UUID:Set<UUID>] = [:]
    func setTracks(_ ids: Set<UUID>, song: UUID?) { if let song { trackSelections[song] = ids } }
    func setClips(_ ids: Set<UUID>, song: UUID?) { if let song { clipSelections[song] = ids } }
    func setRegions(_ ids: Set<UUID>, song: UUID?) { if let song { regionSelections[song] = ids } }
    func tracks(_ song: UUID) -> Set<UUID> { trackSelections[song] ?? [] }
    func clips(_ song: UUID) -> Set<UUID> { clipSelections[song] ?? [] }
    func regions(_ song: UUID) -> Set<UUID> { regionSelections[song] ?? [] }
}
