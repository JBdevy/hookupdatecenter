private struct IpadRegionMovePreview: Equatable { let id: UUID; let start: Double }
private struct IpadNativeItemMove: Equatable { let start: Double }
private struct IpadNativeItemMix: Equatable { let value: Double }
public struct AudioClip { var id = UUID(); var startTime: Double; var duration: Double; var recordingLane: Int? }
public struct Track { var id = UUID(); var clips: [AudioClip] }
public struct Part { var id = UUID(); var startTime: Double; var endTime: Double; var parentRegionID: UUID? }
public struct Song {
    var id = UUID(); var parts: [Part]; var tracks: [Track]
    var markerRegionEnds: [UUID:Double] { [:] }
}
