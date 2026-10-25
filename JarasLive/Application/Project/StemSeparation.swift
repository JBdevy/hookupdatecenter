import Foundation

/// Fixed order of the five offline audio-separation outputs.
public enum CatStem: String, CaseIterable, Codable, Sendable {
    case vocal = "Vocal", drum = "Drum", bass = "Bass", guitar = "Guitar", other = "Other"
    public var role: TrackRole {
        switch self { case .vocal: return .backingVocal; case .drum: return .drums
        case .bass: return .bass; case .guitar: return .guitar; case .other: return .other }
    }
    public var color: UInt32 {
        switch self { case .vocal: return 0xB68AF4; case .drum: return 0x69ED91
        case .bass: return 0x8E70CA; case .guitar: return 0x45BA91; case .other: return 0xAAA0C7 }
    }
}
public enum AudioSeparation {
    public static let audioExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "mp3", "m4a", "aac", "flac", "ogg", "oga", "opus", "caf", "alac", "wma"]
    public static func accepts(_ clip: AudioClip, on track: Track) -> Bool {
        guard track.kind == .standard, clip.midi == nil, clip.text == nil, clip.timecode == nil, clip.duration > 0,
              !clip.isProjectionMedia, !clip.isImage, let file = clip.audioFile ?? track.audioFile else { return false }
        return audioExtensions.contains((file.path as NSString).pathExtension.lowercased())
    }
    public static func outputName(_ stem: CatStem, original: String) -> String {
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = audioExtensions.contains((trimmed as NSString).pathExtension.lowercased())
            ? (trimmed as NSString).deletingPathExtension : trimmed
        return stem.rawValue + " - " + (base.isEmpty ? "Item" : base)
    }
}
public extension Project {
    /// Commit all outputs and source muting as one undoable edit. Never attach
    /// stale results after a project/item edit, or partially insert a separation.
    mutating func insertSeparatedStems(_ tracks: [Track], song songID: UUID,
                                      sourceTrack: UUID, original: AudioClip) throws {
        guard tracks.count == CatStem.allCases.count, Set(tracks.map(\.id)).count == tracks.count,
              tracks.allSatisfy({ $0.kind == .standard && $0.clips.count == 1 && $0.clips[0].startTime == original.startTime && $0.clips[0].duration == original.duration }),
              let song = songs.firstIndex(where: { $0.id == songID }),
              let channel = songs[song].tracks.firstIndex(where: { $0.id == sourceTrack }),
              let item = songs[song].tracks[channel].clips.firstIndex(where: { $0.id == original.id }),
              songs[song].tracks[channel].clips[item] == original else {
            throw ProjectError.invalid("The source item changed. Run Separation audio again.")
        }
        var candidate = self
        candidate.songs[song].tracks[channel].clips[item].muted = true
        candidate.songs[song].tracks[channel].clips[item].separatedStemTracks = tracks.map(\.id)
        // Insert after this track's descendants to preserve folder hierarchy.
        var descendants: Set<UUID> = [sourceTrack]
        var insertion = channel + 1
        while insertion < songs[song].tracks.count,
              let parent = songs[song].tracks[insertion].parentTrackID, descendants.contains(parent) {
            descendants.insert(songs[song].tracks[insertion].id); insertion += 1
        }
        candidate.songs[song].tracks.insert(contentsOf: tracks, at: insertion)
        try candidate.validate()
        self = candidate
    }
}
