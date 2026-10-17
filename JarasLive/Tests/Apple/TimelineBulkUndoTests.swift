import Foundation
@main struct TimelineBulkUndoTests {
    @MainActor static func main() throws {
        for kind in TimelineBulkDeletion.allCases {
            var project = Project.empty(name: "Bulk undo")
            let root = Part(id: UUID(), name: "Unified", startTime: 0, endTime: 20)
            var child = Part(id: UUID(), name: "Member", startTime: 0, endTime: 20); child.parentRegionID = root.id
            var unified = TimelineMarker(id: UUID(), name: "Member", position: 0, color: 0xffff00)
            unified.unifiedRegionID = root.id; unified.sourceRegionID = child.id
            project.songs[0].parts = [root, child]; project.songs[0].duration = 20
            project.songs[0].markers = [unified, TimelineMarker(id: UUID(), name: "Cue", position: 5, color: 0xffffff), TimelineMarker(id: UUID(), name: "Tempo", position: 10, color: 0x999999, tempoBPM: 125, tempoBeats: 4, tempoUnit: 4)]
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = ProjectStore(url: directory.appendingPathComponent("Bulk.jl"))
            let show = try ShowController(executor: LocalCommandExecutor(), persistence: store, initialProject: project)
            let before = show.snapshot.project
            show.deleteTimelineElements(kind, project: before.id, song: before.songs[0].id)
            let after = show.snapshot.project
            precondition(before != after && show.canUndo)
            precondition(!(after.songs[0].markers ?? []).contains(where: kind.matches))
            if kind == .regions { precondition(after.songs[0].parts.isEmpty) }
            else { precondition(after.songs[0].markers!.contains { $0.unifiedRegionID != nil }) }
            show.undo(); precondition(show.snapshot.project == before, "One undo restores all deleted elements")
            show.redo(); precondition(show.snapshot.project == after, "Redo restores exact deletion result")
        }
        var project = Project.empty(name: "Conversion undo")
        project.songs[0].duration = 30
        var track = Track(id: UUID(), name: "Audio", role: .other)
        var clip = AudioClip(id: UUID(), name: "Take", startTime: 0, duration: 20)
        clip.audioFile = AudioFile(path: "Stems/test.wav"); track.clips = [clip]
        project.songs[0].tracks = [track]
        project.songs[0].markers = [TimelineMarker(id: UUID(), name: "Convert", position: 0, color: 0x123456), TimelineMarker(id: UUID(), name: "No audio", position: 5, color: 1)]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let show = try ShowController(executor: LocalCommandExecutor(), persistence: ProjectStore(url: directory.appendingPathComponent("Conversion.jl")), initialProject: project)
        let before = show.snapshot.project, report = show.convertMarkersToRegions(), after = show.snapshot.project
        precondition(after.songs[0].parts.count == 1 && report.contains("Alinhe o marcador"))
        show.undo(); precondition(show.snapshot.project == before)
        show.redo(); precondition(show.snapshot.project == after)
        print("MARKER_CONVERSION_AUDIO_BOUNDS_SINGLE_UNDO_REDO_OK")
        print("BULK_TIMELINE_CATEGORIES_UNIFIED_PROTECTION_SINGLE_UNDO_REDO_OK")
    }
}
