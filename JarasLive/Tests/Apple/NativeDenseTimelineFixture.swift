private struct IpadRegionMovePreview: Equatable { let id: UUID; let start: Double }
private struct IpadNativeItemMove: Equatable { let start: Double }
private struct IpadNativeItemMix: Equatable { let value: Double }
public struct AudioClip { var id = UUID(); var startTime: Double; var duration: Double; var recordingLane: Int?; var isImage = false; var audioFile: URL? }
public struct Track { var id = UUID(); var clips: [AudioClip]; var usesStackedStems = false; var kind = TrackKind(); var audioFile: URL? }
public struct Part { var id = UUID(); var startTime: Double; var endTime: Double; var parentRegionID: UUID? }
public struct Song {
    var id = UUID(); var parts: [Part]; var tracks: [Track]
    var markerRegionEnds: [UUID:Double] { [:] }
}

struct TrackKind { var isTeleprompter = false }
struct TimelineTempoSection { var end: Double }
extension Song {
    var duration: Double { parts.map(\.endTime).max() ?? 0 }
    var timelineScrollEnd: Double { duration }
    func tempoSections(until end: Double) -> [TimelineTempoSection] { [.init(end: end)] }
    func tempoAudioSegments(_ clip: AudioClip, sections: [TimelineTempoSection]?) -> [AudioClip] { [clip] }
}
struct TimelineMediaURLCache {
    typealias Source = URL
    func resolveSource(_ path: String, directory: URL) -> URL {
        URL(fileURLWithPath: path, relativeTo: directory)
    }
}
