import Foundation

public struct TrackRole: Codable, Hashable, Sendable, RawRepresentable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let click = Self(rawValue: "click"), guide = Self(rawValue: "guide"), drums = Self(rawValue: "drums"), bass = Self(rawValue: "bass"), guitar = Self(rawValue: "guitar"), keys = Self(rawValue: "keys"), accordion = Self(rawValue: "accordion"), backingVocal = Self(rawValue: "backingVocal"), fx = Self(rawValue: "fx"), other = Self(rawValue: "other")
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(rawValue) }
}
public struct AudioFile: Codable, Equatable, Sendable { public var path: String; public var sha256: String? }
public struct AudioClip: Codable, Identifiable, Equatable, Sendable { public var id: UUID; public var name: String; public var startTime: Double; public var duration: Double; public var sourceOffset: Double = 0; public var waveform: [Double] = [] }
public struct Track: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID; public var name: String; public var role: TrackRole
    public var volume: Double = 0.8, pan: Double = 0
    public var mute = false, solo = false
    public var output = 1
    public var audioFile: AudioFile?
    public var clips: [AudioClip] = []
}
public struct Part: Codable, Identifiable, Equatable, Sendable { public var id: UUID; public var name: String; public var startTime: Double; public var endTime: Double }
public struct Song: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID; public var name: String; public var duration: Double; public var bpm: Double
    public var tracks: [Track]; public var parts: [Part]
}
public struct Setlist: Codable, Identifiable, Equatable, Sendable { public var id: UUID; public var name: String; public var songIds: [UUID] }
public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID; public var name: String
    public var projectFormatVersion = 1, minimumJarasVersion = "1.0.0"
    public var createdAt: String, updatedAt: String
    public var setlists: [Setlist]; public var songs: [Song]
    public func validate() throws {
        guard projectFormatVersion == 1, minimumJarasVersion == "1.0.0", !name.isEmpty else { throw ProjectError.invalid("Versão ou nome do projeto inválido.") }
        var identifiers: Set<UUID> = [id]
        func register(_ id: UUID) throws { guard identifiers.insert(id).inserted else { throw ProjectError.invalid("UUID duplicado.") } }
        for song in songs {
            try register(song.id)
            guard song.duration.isFinite, song.duration > 0, song.bpm.isFinite, song.bpm > 0 else { throw ProjectError.invalid("Tempo de música inválido.") }
            for track in song.tracks {
                try register(track.id)
                guard track.volume.isFinite, (0...1).contains(track.volume), track.pan.isFinite, (-1...1).contains(track.pan), track.output > 0 else { throw ProjectError.invalid("Controle de pista inválido.") }
                for clip in track.clips {
                    try register(clip.id)
                    guard clip.startTime.isFinite, clip.duration.isFinite, clip.startTime >= 0, clip.duration > 0, clip.startTime + clip.duration <= song.duration, clip.sourceOffset.isFinite, clip.sourceOffset >= 0, clip.waveform.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw ProjectError.invalid("Bloco de áudio inválido.") }
                }
                if let file = track.audioFile {
                    let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
                    guard !file.path.isEmpty, !file.path.contains("\\"), !file.path.contains(":"), parts.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." }) else { throw ProjectError.invalid("Use caminhos relativos para o áudio.") }
                    if let hash = file.sha256 { guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw ProjectError.invalid("SHA-256 inválido.") } }
                }
            }
            for part in song.parts {
                try register(part.id)
                guard part.startTime.isFinite, part.endTime.isFinite, part.startTime >= 0, part.endTime > part.startTime, part.endTime <= song.duration else { throw ProjectError.invalid("Intervalo da parte inválido.") }
            }
        }
        let songIDs = Set(songs.map(\.id))
        for setlist in setlists {
            try register(setlist.id)
            guard Set(setlist.songIds).count == setlist.songIds.count, setlist.songIds.allSatisfy(songIDs.contains) else { throw ProjectError.invalid("Repertório inválido.") }
        }
    }
    public static func demo() -> Project {
        let names = ["Abertura", "Música 01", "Música 02", "Música 03", "Final"]
        let roles: [(String,TrackRole)] = [("Click",.click),("Guia",.guide),("Drums",.drums),("Percussão",.drums),("Bass",.bass),("Guitar L",.guitar),("Guitar R",.guitar),("Keys",.keys),("Strings",.keys),("Sanfona",.accordion),("Backing Vocal",.backingVocal),("FX",.fx)]
        let songs = names.enumerated().map { index, name -> Song in
            let duration = [96.0, 216, 240, 192, 120][index]
            let tracks = roles.enumerated().map { trackIndex, pair -> Track in
                var track = Track(id: UUID(), name: pair.0, role: pair.1)
                let sections = trackIndex < 5 ? 4 : 6
                for section in 0..<sections {
                    if trackIndex > 4 && (section + trackIndex) % 3 == 0 { continue }
                    let step = duration / Double(sections)
                    let start = Double(section) * step
                    let length = step * (trackIndex < 5 ? 1 : 0.85)
                    // Explicit demo overview, not analysis of a real audio file.
                    let peaks = (0..<96).map { sample in
                        let pulse = abs(sin(Double(sample * (trackIndex + 3) + section) * 0.43))
                        return 0.08 + pulse * (trackIndex < 5 ? 0.83 : 0.58)
                    }
                    track.clips.append(AudioClip(id: UUID(), name: pair.0, startTime: start, duration: length, waveform: peaks))
                }
                return track
            }
            let parts = ["Intro", "Verso", "Refrão", "Final"].enumerated().map { partIndex, title in
                Part(id: UUID(), name: title, startTime: Double(partIndex) * duration / 4, endTime: Double(partIndex + 1) * duration / 4)
            }
            return Song(id: UUID(), name: name, duration: duration, bpm: [96.0, 124, 108, 132, 90][index], tracks: tracks, parts: parts)
        }
        let date = ISO8601DateFormatter().string(from: Date())
        return Project(id: UUID(), name: "Show de demonstração", createdAt: date, updatedAt: date, setlists: [Setlist(id: UUID(), name: "Repertório principal", songIds: songs.map(\.id))], songs: songs)
    }
}
public enum ProjectError: LocalizedError { case invalid(String); public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil } }
public struct QueueState: Codable, Equatable, Sendable { public var songId: UUID? }
public struct LoopState: Codable, Equatable, Sendable { public var enabled: Bool }
public struct SubPlayState: Codable, Equatable, Sendable { public var playing: Bool; public var position: Double }
public struct TransportState: Codable, Equatable, Sendable {
    public var playing: Bool; public var songId: UUID?; public var position: Double
    public var queue: QueueState; public var loop: LoopState; public var subPlay: SubPlayState
}
public struct AudioRoute: Codable, Sendable { public var trackId: UUID; public var output: Int }
public struct AudioRouting: Codable, Sendable { public var routes: [AudioRoute] }
public struct MixerState: Codable, Sendable { public var tracks: [Track]; public var routing: AudioRouting }
public struct ShowSnapshot: Codable, Sendable { public var project: Project; public var transport: TransportState; public var nextSongId: UUID? }

public struct PlaybackSnapshot: Codable, Sendable { public var transport: TransportState; public var nextSongId: UUID? }
