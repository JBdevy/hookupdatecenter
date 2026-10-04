import Foundation

public struct GluedItemReplacement: Sendable {
    public let track: UUID
    public let originals: [AudioClip]
    public let rendered: AudioClip
    public init(track: UUID, originals: [AudioClip], rendered: AudioClip) {
        self.track = track; self.originals = originals; self.rendered = rendered
    }
}

/// A single new source spans the selected items on one track. Different source
/// paths cannot share one resulting item without changing their processing.
public enum ItemGlue {
    public static func validate(track: Track, clips: [AudioClip]) throws {
        guard track.kind == .standard, !clips.isEmpty,
              Set(clips.map(\.id)).count == clips.count,
              clips.allSatisfy({ $0.duration > 0 && $0.startTime.isFinite && $0.duration.isFinite }) else {
            throw ProjectError.invalid("Select audio or MIDI items to unify.")
        }
        guard clips.allSatisfy({ $0.midi != nil || ($0.audioFile ?? track.audioFile) != nil }) else {
            throw ProjectError.invalid("Select audio or MIDI items to unify.")
        }
    }

    public static func midi(song: Song, track: Track, clips: [AudioClip]) throws -> AudioClip {
        try validate(track: track, clips: clips)
        guard clips.allSatisfy({ $0.midi != nil }) else { throw ProjectError.invalid("Select MIDI items to unify.") }
        let ordered = clips.sorted { $0.startTime == $1.startTime ? $0.id.uuidString < $1.id.uuidString : $0.startTime < $1.startTime }
        let start = ordered[0].startTime, end = ordered.map { $0.startTime + $0.duration }.max()!
        let allMuted = ordered.allSatisfy { $0.muted == true }
        var result = AudioClip(id: UUID(), name: ordered[0].name, startTime: start, duration: end - start,
                               muted: allMuted ? true : nil, recordingLane: ordered[0].recordingLane)
        // Invert the new item's tempo map so its playback reproduces each old
        // item's audible positions, including source trims and stretched notes.
        let segments = song.tempoAudioSegments(result)
        func beat(_ position: Double) -> Double {
            var low = 0, high = segments.count
            while low < high { let mid = (low + high) / 2; if segments[mid].startTime <= position { low = mid + 1 } else { high = mid } }
            guard low > 0 else { return 0 }
            let segment = segments[low - 1]
            return max(0, segment.sourceOffset + (min(end, position) - segment.startTime) * segment.audioRate) * 2
        }
        var notes: [MIDINote] = []
        for var clip in ordered {
            if allMuted { clip.muted = false }
            for note in song.midiPlaybackNotes(in: clip) {
                let begin = beat(note.start), finish = beat(note.end)
                guard finish > begin else { continue }
                notes.append(MIDINote(start: begin, length: finish - begin, pitch: note.pitch, velocity: note.velocity, channel: note.channel))
            }
        }
        notes.sort { $0.start == $1.start ? ($0.channel == $1.channel ? $0.pitch < $1.pitch : $0.channel < $1.channel) : $0.start < $1.start }
        result.midi = MIDIItem(notes: notes, sourceBPM: 120, grid: ordered[0].midi!.grid)
        try result.midi!.validate()
        return result
    }
}
